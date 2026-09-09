mutable struct AsyncExecutor <: AbstractExecutor
    workers::Int
    queuesize::Int
    worker_tasks::Vector{Task}
    calls::Channel{Function}
    replies::Channel{Tagged{Union{Response,StreamResponse,Message}}}
    inflight::Threads.Atomic{Int}
end

@doc """
    AsyncExecutor — bounded worker pool with a reply queue.

    Architecture:
    - Transport submits closures (`() → Union{Nothing,Tagged}`) via `submit!`.
    - `workers` threads dequeue and run jobs, pushing replies onto `replies`.
    - The event loop drains `replies` (see `dispatch_replies!`) and sends them
      through the transport's connections.
    - `supervise_workers!` respawns dead workers on a timer.

    The executor never interprets requests/responses; it only runs jobs and
    ships the replies they produce. Timeout policy is applied by the transport
    when it builds a job.
""" AsyncExecutor

function AsyncExecutor(workers::Int, queuesize::Int)
    return AsyncExecutor(workers, queuesize, Task[],
        Channel{Function}(queuesize),
        Channel{Tagged{Union{Response,StreamResponse,Message}}}(queuesize),
        Threads.Atomic{Int}(0))
end

# --- Lifecycle ---

function init_executor!(exec::AsyncExecutor)
    exec.calls = Channel{Function}(exec.queuesize)
    exec.replies = Channel{Tagged{Union{Response,StreamResponse,Message}}}(exec.queuesize)
    empty!(exec.worker_tasks)
    return exec
end

function start!(exec::AsyncExecutor, app)
    spawn_workers!(exec)
    return exec
end

function spawn_workers!(exec::AsyncExecutor)
    empty!(exec.worker_tasks)
    for _ in 1:exec.workers
        push!(exec.worker_tasks, Threads.@spawn worker_loop(exec))
    end
end

function stop!(exec::AsyncExecutor)
    close(exec.calls)
    for t in exec.worker_tasks
        try wait(t) catch end
    end
    close(exec.replies)
    empty!(exec.worker_tasks)
    return exec
end

haspending(exec::AsyncExecutor) =
    isready(exec.calls) || isready(exec.replies) || exec.inflight[] > 0

# --- Submission ---

@inline function submit!(exec::AsyncExecutor, job::Function)
    isopen(exec.calls) || return false
    Base.n_avail(exec.calls) >= exec.queuesize && return false
    try
        put!(exec.calls, job)
    catch e
        e isa InvalidStateException || rethrow(e)
        return false
    end
    return true
end

# --- Worker loop ---

function worker_loop(exec::AsyncExecutor)
    try
        for job in exec.calls
            Threads.atomic_add!(exec.inflight, 1)
            try
                reply = job()
                reply === nothing && continue
                isopen(exec.replies) && put!(exec.replies, reply)
            finally
                Threads.atomic_sub!(exec.inflight, 1)
            end
        end
    catch e
        e isa InvalidStateException || rethrow(e)
    end
end

# --- Supervisor ---

function supervise_workers!(exec::AsyncExecutor)
    for i in eachindex(exec.worker_tasks)
        t = exec.worker_tasks[i]
        if istaskdone(t)
            istaskfailed(t) && @log_warn "Worker $i died, respawning"
            exec.worker_tasks[i] = Threads.@spawn worker_loop(exec)
        end
    end
end

# --- App wiring (server-level orchestration) ---

function init_server!(app::App)
    app.runtime.manager = Manager()
    app.executor isa AsyncExecutor && init_executor!(app.executor)
    empty!(app.runtime.connections)
    empty!(app.runtime.streams)
    empty!(app.runtime.ws_clients)
end

haspending(app::App) = app.executor isa AsyncExecutor ? haspending(app.executor) : false

function drain_poll!(app::App)
    mg_mgr_poll(app.runtime.manager.ptr, 10)
    dispatch_replies!(app)
end

function dispatch_replies!(app::App)::Bool
    exec = app.executor
    exec === nothing && return false
    did_ws = false
    while isopen(exec.replies) && isready(exec.replies)
        reply = try take!(exec.replies) catch e; e isa InvalidStateException && break; rethrow(e) end
        conn = get(app.runtime.connections, reply.id, nothing)
        conn === nothing && continue
        if reply.payload isa Response
            send_http_response!(conn, reply.payload)
            delete!(app.runtime.connections, reply.id)
        elseif reply.payload isa StreamResponse
            try send_stream_response!(app, conn, reply.payload) catch e; @log_error "Stream error" e catch_backtrace() end
            delete!(app.runtime.connections, reply.id)
        else  # Message (WebSocket)
            try
                send_ws_frame!(conn, reply.payload)
                did_ws = true
            catch e
                @log_error "WebSocket send error" e catch_backtrace()
            end
        end
    end
    return did_ws
end
