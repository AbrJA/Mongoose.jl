mutable struct AsyncExecutor <: AbstractExecutor
    workers::Int
    queue_size::Int
    worker_tasks::Vector{Task}
    calls::Channel{Function}
    replies::Channel{Tagged{Union{Response,StreamResponse,Message}}}
    inflight::Threads.Atomic{Int}
    stopping::Threads.Atomic{Bool}
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

function AsyncExecutor(workers::Int, queue_size::Int)
    return AsyncExecutor(workers, queue_size, Task[],
        Channel{Function}(queue_size),
        Channel{Tagged{Union{Response,StreamResponse,Message}}}(queue_size),
        Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false))
end

# --- Lifecycle ---

function init_executor!(exec::AsyncExecutor)
    exec.calls = Channel{Function}(exec.queue_size)
    exec.replies = Channel{Tagged{Union{Response,StreamResponse,Message}}}(exec.queue_size)
    exec.stopping[] = false
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

"""
    stop!(exec::AsyncExecutor; timeout=5.0)

Stop the worker pool. `calls` is closed first, then replies are drained while
workers are joined so a full reply queue cannot deadlock the join. The join is
bounded by `timeout` seconds: a handler that never returns is abandoned (its
task keeps running, as before) instead of hanging shutdown forever.
"""
function stop!(exec::AsyncExecutor; timeout::Real=5.0)
    exec.stopping[] = true
    close(exec.calls)
    deadline = time() + timeout
    while time() < deadline
        all(istaskdone, exec.worker_tasks) && break
        # Consume replies so workers blocked in put! can finish their loop.
        while isready(exec.replies)
            try take!(exec.replies) catch; break; end
        end
        yield()
    end
    if !all(istaskdone, exec.worker_tasks)
        @log_warn "Executor stop: $(count(!istaskdone, exec.worker_tasks)) worker(s) still running after $(timeout)s; abandoning"
    end
    close(exec.replies)
    empty!(exec.worker_tasks)
    return exec
end

haspending(exec::AsyncExecutor) =
    isready(exec.calls) || isready(exec.replies) || exec.inflight[] > 0

# --- Submission ---

@inline function submit!(exec::AsyncExecutor, job::F) where {F<:Function}
    isopen(exec.calls) || return false
    Base.n_avail(exec.calls) >= exec.queue_size && return false
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
    for job in exec.calls
        Threads.atomic_add!(exec.inflight, 1)
        try
            reply = job()
            reply === nothing && continue
            isopen(exec.replies) && put!(exec.replies, reply)
        catch e
            # A failing job must not kill the worker (and thus the pool).
            e isa InvalidStateException ||
                @log_error "Worker job error" e catch_backtrace()
        finally
            Threads.atomic_sub!(exec.inflight, 1)
        end
    end
end

# --- Supervisor ---

function supervise_workers!(exec::AsyncExecutor)
    exec.stopping[] && return nothing
    for i in eachindex(exec.worker_tasks)
        t = exec.worker_tasks[i]
        if istaskdone(t)
            istaskfailed(t) && @log_warn "Worker $i died, respawning"
            exec.worker_tasks[i] = Threads.@spawn worker_loop(exec)
        end
    end
    return nothing
end

# Async executor shutdown uses the configured drain budget.
_stop_executor(exec::AsyncExecutor, timeout::Real) = stop!(exec; timeout=timeout)

# --- App wiring (server-level orchestration) ---

function init_server!(app::App)
    app.runtime.manager = Manager()
    _init_executor!(app.executor)
    empty!(app.runtime.connections)
    empty!(app.runtime.streams)
    empty!(app.runtime.ws_clients)
    empty!(app.runtime.ws_gen_ids)
    empty!(app.runtime.conn_times)
    empty!(app.runtime.awaiting_headers)
    empty!(app.runtime.conn_addr)
end

# Executor-specific barriers: `App{R,E}` carries the concrete executor, so
# these resolve statically instead of an `isa` branch per call.
_init_executor!(::SyncExecutor) = nothing
_init_executor!(exec::AsyncExecutor) = init_executor!(exec)

haspending(app::App) = _haspending(app.executor, app)
_haspending(::SyncExecutor, app::App) = !isempty(app.runtime.streams)
_haspending(exec::AsyncExecutor, app::App) = haspending(exec) || !isempty(app.runtime.streams)

function drain_poll!(app::App)
    mg_mgr_poll(app.runtime.manager.ptr, 10)
    dispatch_replies!(app)
    # The event loop may already have exited during shutdown; drain streams
    # here too so `drain!` can actually finish them (poll-thread only).
    drain_streams!(app)
end

dispatch_replies!(app::App)::Bool = _dispatch_replies!(app.executor, app)
_dispatch_replies!(::SyncExecutor, app::App)::Bool = false

function _dispatch_replies!(exec::AsyncExecutor, app::App)::Bool
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
