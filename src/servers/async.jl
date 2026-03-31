"""
    AsyncServer — Multi-threaded server methods.
"""

"""
    AsyncServer(router=Router(); workers=4, nqueue=1024, timeout=0, max_body_size,
               drain_timeout_ms, request_timeout_ms=0, error_responses=Dict{Int,Response}())

Create a multi-threaded server with `workers` background tasks.
Not compatible with `juliac --trim=safe`.

# Keyword Arguments
- `workers::Integer`: Number of worker tasks (default: `4`).
- `nqueue::Integer`: Channel buffer size (default: `1024`).
- `timeout::Integer`: Event-loop poll timeout in ms (default: `0`).
- `max_body_size::Integer`: Maximum request body size in bytes (default: 1MB).
- `drain_timeout_ms::Integer`: Graceful shutdown drain timeout (default: 5000ms).
- `request_timeout_ms::Integer`: Per-request timeout in ms, 0 = disabled (default: `0`).
- `error_responses::Dict{Int,Response}`: Custom responses keyed by HTTP status code (`500`, `413`, `504`). See `error_response!`.
"""
AsyncServer(::Type{T}; kwargs...) where {T <: StaticRouter} = AsyncServer(T(); kwargs...)

function AsyncServer(router::AbstractRouter=Router();
                     workers::Integer=4,
                     nqueue::Integer=1024,
                     timeout::Integer=0,
                     max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                     drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS,
                     request_timeout_ms::Integer=0,
                     error_responses::Dict{Int,Response}=Dict{Int,Response}())
    c_handler = Mongoose._cfnasync(typeof(router))
    core = ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms,
                      request_timeout_ms=request_timeout_ms, error_responses=error_responses, c_handler=c_handler)
    server = AsyncServer{typeof(router)}(
        core, Task[],
        Channel{Call}(nqueue), Channel{Reply}(nqueue),
        Dict{Int,MgConnection}(), Int(workers), Int(nqueue)
    )
    finalizer(_teardown!, server)
    return server
end

function _init!(server::AsyncServer)
   server.core.manager = Manager()
   server.calls  = Channel{Call}(server.nqueue)
   server.replies   = Channel{Reply}(server.nqueue)
   empty!(server.connections)
   empty!(server.core.ws_connections)
   return
end

function _spawnworkers!(server::AsyncServer)
    empty!(server.workers)
    for i in 1:server.nworkers
        t = Threads.@spawn _workloop(server)
        push!(server.workers, t)
    end
end

_spawnworkers!(::AbstractServer) = nothing

function _stopworkers!(server::AsyncServer)
    # Close channels to unblock any workers stuck on take!
    close(server.calls)
    close(server.replies)

    for t in server.workers
        try wait(t) catch end
    end
    empty!(server.workers)
end

_stopworkers!(::AbstractServer) = nothing

function _eventloop(server::AsyncServer)
    server.core.running[] = true
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)

        # Dispatch replies from workers back to C library
        local did_ws_send = false
        while isopen(server.replies) && isready(server.replies)
            id_res = take!(server.replies)
            conn = get(server.connections, id_res.id, nothing)
            if conn !== nothing
                if id_res.payload isa Response
                    _send!(conn, id_res.payload)
                    delete!(server.connections, id_res.id)
                else  # Message
                    try
                        _wssend!(conn, id_res.payload)
                        did_ws_send = true
                    catch e
                        @error "WebSocket send error" exception=(e, catch_backtrace())
                    end
                end
            end
        end
        # Extra poll to flush mg_ws_send buffers immediately
        did_ws_send && mg_mgr_poll(server.core.manager.ptr, 1)
        yield()
    end
end

function _workloop(server::AsyncServer)
    timeout_ms = server.core.request_timeout_ms
    try
        for req in server.calls     # blocks properly — no sleep needed
            if req.payload isa Request
                rid = _nextreqid!(server)
                res = try
                    if timeout_ms > 0
                        _servehttp_timeout(server, req.payload, timeout_ms)
                    else
                        _servehttp(server, req.payload)
                    end
                catch e
                    @error "Handler error" exception=(e, catch_backtrace())
                    _handleerror(server, req.payload, e)
                end
                res = Response(res.status, res.headers * "X-Request-Id: $(rid)\r\n", res.body)
                isopen(server.replies) && put!(server.replies, Tagged(req.id, res))
            else  # Intent
                res = _handlewsmsg!(server, req)
                res !== nothing && isopen(server.replies) && put!(server.replies, res)
            end
        end
    catch e
        e isa InvalidStateException || rethrow(e)
    end
end

_haspending(server::AsyncServer) = isready(server.calls) || isready(server.replies)
