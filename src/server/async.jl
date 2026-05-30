"""
    Async{R} — Multi-threaded server with worker pool.

    Architecture:
    - Event loop (single thread): accepts connections, dispatches to workers
    - Worker pool (N threads): process requests, send replies via Channel
    - Supervisor: respawns dead workers every 2 seconds
"""

Async(::Type{T}; kwargs...) where {T<:StaticRouter} = Async(T(); kwargs...)
Async(::Type{T}, config::Config) where {T<:StaticRouter} = Async(T(), config)

function Async(router::AbstractRouter=Router();
               nworkers::Integer=4,
               nqueue::Integer=1024,
               poll_timeout::Integer=0,
               max_body::Integer=MAX_BODY,
               drain_timeout::Integer=DRAIN_TIMEOUT,
               request_timeout::Integer=0,
               ws_max_frame::Integer=MAX_BODY,
               ws_idle_timeout::Integer=0,
               errors::Dict{Int,Response}=Dict{Int,Response}(),
               services::Union{Nothing,ServiceRegistry}=nothing)
    nworkers > 0 || throw(ServerError("nworkers must be > 0"))
    nqueue > 0 || throw(ServerError("nqueue must be > 0"))

    c_handler = cfunc_async(typeof(router))
    core = ServerCore(router; poll_timeout=poll_timeout, max_body=max_body,
                      drain_timeout=drain_timeout, request_timeout=request_timeout,
                      ws_max_frame=ws_max_frame, ws_idle_timeout=ws_idle_timeout,
                      errors=errors, services=services, c_handler=c_handler)
    server = Async{typeof(router)}(
        core, Task[],
        Channel{Call}(nqueue), Channel{Reply}(nqueue),
        Dict{Int,MgConnection}(), Int(nworkers), Int(nqueue),
        Threads.Atomic{Int}(0)
    )
    finalizer(teardown!, server)
    return server
end

function Async(router::AbstractRouter, config::Config;
               services::Union{Nothing,ServiceRegistry}=nothing)
    validate_config!(config)
    return Async(router; nworkers=config.nworkers, nqueue=config.nqueue,
                 poll_timeout=config.poll_timeout, max_body=config.max_body,
                 drain_timeout=config.drain_timeout, request_timeout=config.request_timeout,
                 ws_max_frame=config.ws_max_frame, ws_idle_timeout=config.ws_idle_timeout,
                 errors=config.errors, services=services)
end

function init_server!(server::Async)
    server.core.manager = Manager()
    server.calls = Channel{Call}(server.nqueue)
    server.replies = Channel{Reply}(server.nqueue)
    empty!(server.connections)
    empty!(server.core.ws_clients)
end

function spawn_workers!(server::Async)
    empty!(server.workers)
    for _ in 1:server.nworkers
        push!(server.workers, Threads.@spawn worker_loop(server))
    end
end

function stop_workers!(server::Async)
    close(server.calls)
    for t in server.workers
        try wait(t) catch end
    end
    close(server.replies)
    empty!(server.workers)
end

has_pending(s::Async) = isready(s.calls) || isready(s.replies) || s.inflight[] > 0

function drain_poll!(server::Async)
    mg_mgr_poll(server.core.manager.ptr, 10)
    dispatch_replies!(server)
end

# --- Event Loop ---

function event_loop(server::Async)
    last_sweep = time()
    last_health = time()
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.poll_timeout)

        # Dispatch replies from workers → connections
        did_ws = dispatch_replies!(server)
        did_ws && mg_mgr_poll(server.core.manager.ptr, 1)

        now = time()

        # Supervisor check every 2s
        if (now - last_health) >= 2.0
            supervise_workers!(server)
            last_health = now
        end

        # WS idle sweep every 5s
        if server.core.ws_idle_timeout > 0 && !isempty(server.core.ws_clients)
            if (now - last_sweep) >= 5.0
                ws_idle_sweep!(server)
                last_sweep = now
            end
        end
        yield()
    end
end

# --- Reply Dispatch ---

function dispatch_replies!(server::Async)::Bool
    did_ws = false
    while isopen(server.replies) && isready(server.replies)
        reply = try take!(server.replies) catch e; e isa InvalidStateException && break; rethrow(e) end
        conn = get(server.connections, reply.id, nothing)
        conn === nothing && continue
        if reply.payload isa Response
            send_http_response!(conn, reply.payload)
            delete!(server.connections, reply.id)
        elseif reply.payload isa StreamResponse
            # Streaming: write chunked body directly on the event-loop thread
            try send_stream_response!(conn, reply.payload) catch e; @log_error "Stream error" e catch_backtrace() end
            delete!(server.connections, reply.id)
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

function worker_loop(server::Async)
    timeout = server.core.request_timeout
    try
        for tagged_req in server.calls
            Threads.atomic_add!(server.inflight, 1)
            try
                if tagged_req.payload isa Request
                    rid = resolve_request_id(tagged_req.payload, server)
                    res = try
                        if timeout > 0
                            invoke_timed_http(server, tagged_req.payload, timeout)
                        else
                            invoke_http(server, tagged_req.payload)
                        end
                    catch e
                        @log_error "Handler error uri=$(tagged_req.payload.uri)" e catch_backtrace()
                        error_response(server, 500)
                    end
                    # For StreamResponse: send as-is via the replies channel (dispatch_replies! handles it)
                    # For Response: inject X-Request-Id header
                    tagged_res = if res isa StreamResponse
                        Tagged{Union{Response,StreamResponse,Message}}(tagged_req.id, res)
                    else
                        resp_with_id = Response(res.status, string(res.headers, "X-Request-Id: ", rid, "\r\n"), res.body)
                        Tagged{Union{Response,StreamResponse,Message}}(tagged_req.id, resp_with_id)
                    end
                    try isopen(server.replies) && put!(server.replies, tagged_res) catch end
                else  # Intent (WebSocket)
                    ws_tagged = Tagged{Intent}(tagged_req.id, tagged_req.payload::Intent)
                    res = invoke_ws(server, ws_tagged)
                    try res !== nothing && isopen(server.replies) && put!(server.replies, res) catch end
                end
            finally
                Threads.atomic_sub!(server.inflight, 1)
            end
        end
    catch e
        e isa InvalidStateException || rethrow(e)
    end
end

# --- Supervisor ---

function supervise_workers!(server::Async)
    for i in eachindex(server.workers)
        t = server.workers[i]
        if istaskdone(t)
            istaskfailed(t) && @log_warn "Worker $i died, respawning"
            server.workers[i] = Threads.@spawn worker_loop(server)
        end
    end
end

# --- Non-blocking enqueue ---

"""
    try_enqueue!(channel, value, capacity) → Bool

Non-blocking put. Returns false if channel is full or closed (prevents event loop stall).
"""
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
        return error_response(server, 503)
    end

    ch = Channel{Union{Response,StreamResponse}}(1)
    Threads.@spawn begin
        try
            res = try
                invoke_http(server, req)
            catch e
                @log_error "Handler error uri=$(req.uri)" e catch_backtrace()
                error_response(server, 500)
            end
            try put!(ch, res) catch end
        finally
            Threads.atomic_sub!(_TIMED_INFLIGHT, 1)
        end
    end

    result = timedwait(timeout / 1000.0) do
        isready(ch)
    end
    if result === :timed_out
        close(ch)
        @log_warn "Request timed out uri=$(req.uri) timeout_ms=$timeout"
        return error_response(server, 504)
    end
    return take!(ch)
end
