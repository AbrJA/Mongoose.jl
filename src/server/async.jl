"""
    Async worker pool for App (workers>0).

    Architecture:
    - Event loop branches on app.workers in sync.jl
    - Worker pool (N threads): process requests, send replies via reply channel
    - Supervisor: respawns dead workers every 2 seconds
"""

function init_server!(app::App)
    app.manager = Manager()
    app.calls = Channel{Tagged{Union{Request,Intent}}}(app.queuesize)
    app.replies = Channel{Tagged{Union{Response,StreamResponse,Message}}}(app.queuesize)
    empty!(app.connections)
    empty!(app.ws_clients)
end

function spawn_workers!(app::App)
    empty!(app.worker_tasks)
    for _ in 1:app.workers
        push!(app.worker_tasks, Threads.@spawn worker_loop(app))
    end
end

function stop_workers!(app::App)
    close(app.calls)
    for t in app.worker_tasks
        try wait(t) catch end
    end
    close(app.replies)
    empty!(app.worker_tasks)
end

has_pending(app::App) = isready(app.calls) || isready(app.replies) || app.inflight[] > 0

function drain_poll!(app::App)
    mg_mgr_poll(app.manager.ptr, 10)
    dispatch_replies!(app)
end

# --- Reply Dispatch ---

function dispatch_replies!(app::App)::Bool
    did_ws = false
    while isopen(app.replies) && isready(app.replies)
        reply = try take!(app.replies) catch e; e isa InvalidStateException && break; rethrow(e) end
        conn = get(app.connections, reply.id, nothing)
        conn === nothing && continue
        if reply.payload isa Response
            send_http_response!(conn, reply.payload)
            delete!(app.connections, reply.id)
        elseif reply.payload isa StreamResponse
            try send_stream_response!(conn, reply.payload) catch e; @log_error "Stream error" e catch_backtrace() end
            delete!(app.connections, reply.id)
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

# --- Worker Loop ---

function worker_loop(app::App)
    timeout = app.request_timeout
    try
        for tagged_req in app.calls
            Threads.atomic_add!(app.inflight, 1)
            try
                if tagged_req.payload isa Request
                    rid = resolve_request_id(tagged_req.payload, app)
                    res = try
                        if timeout > 0
                            invoke_timed_http(app, tagged_req.payload, timeout)
                        else
                            invoke_http(app, tagged_req.payload)
                        end
                    catch e
                        @log_error "Handler error uri=$(tagged_req.payload.uri)" e catch_backtrace()
                        error_response(app.errors, tagged_req.payload, 500)
                    end
                    tagged_res = if res isa StreamResponse
                        Tagged{Union{Response,StreamResponse,Message}}(tagged_req.id, res)
                    else
                        resp_with_id = Response(res.status,
                            [res.headers; ["X-Request-Id" => rid]],
                            res.body)
                        Tagged{Union{Response,StreamResponse,Message}}(tagged_req.id, resp_with_id)
                    end
                    try isopen(app.replies) && put!(app.replies, tagged_res) catch end
                else  # Intent (WebSocket)
                    ws_tagged = Tagged{Intent}(tagged_req.id, tagged_req.payload::Intent)
                    res = invoke_ws(app, ws_tagged)
                    try res !== nothing && isopen(app.replies) && put!(app.replies, res) catch end
                end
            finally
                Threads.atomic_sub!(app.inflight, 1)
            end
        end
    catch e
        e isa InvalidStateException || rethrow(e)
    end
end

# --- Supervisor ---

function supervise_workers!(app::App)
    for i in eachindex(app.worker_tasks)
        t = app.worker_tasks[i]
        if istaskdone(t)
            istaskfailed(t) && @log_warn "Worker $i died, respawning"
            app.worker_tasks[i] = Threads.@spawn worker_loop(app)
        end
    end
end

# --- Non-blocking enqueue ---

@inline function try_enqueue!(ch::Channel, val, capacity::Int)::Bool
    isopen(ch) || return false
    Base.n_avail(ch) >= capacity && return false
    try
        put!(ch, val)
    catch e
        e isa InvalidStateException || rethrow(e)
        return false
    end
    return true
end

# --- Timed HTTP execution ---

const _TIMED_INFLIGHT = Threads.Atomic{Int}(0)
const _MAX_TIMED = max(Threads.nthreads() * 2, 8)

function invoke_timed_http(server::AbstractServer, req::Request, timeout::Integer)::Union{Response,StreamResponse}
    current = Threads.atomic_add!(_TIMED_INFLIGHT, 1)
    if current >= _MAX_TIMED
        Threads.atomic_sub!(_TIMED_INFLIGHT, 1)
        @log_warn "Timed request limit reached uri=$(req.uri)"
        return error_response(server.errors, 503)
    end
    t = Threads.@spawn invoke_http(server, req)
    try
        r = timedwait(() -> istaskdone(t), timeout / 1000.0; pollint=0.002)
        if r === :ok
            return fetch(t)
        else
            @log_warn "Request timeout uri=$(req.uri)"
            return error_response(server.errors, 504)
        end
    finally
        Threads.atomic_sub!(_TIMED_INFLIGHT, 1)
    end
end
