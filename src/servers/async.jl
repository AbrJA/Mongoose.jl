"""
    AsyncServer — Multi-threaded server methods.
"""

"""
    AsyncServer(router=Router(); workers=4, nqueue=1024, poll_timeout=0, max_body,
               drain_timeout, request_timeout=0, errors=Dict{Int,Response}())

Create a multi-threaded server with `workers` background tasks.
Not compatible with `juliac --trim=safe`.

# Keyword Arguments
- `workers::Integer`: Number of worker tasks (default: `4`).
- `nqueue::Integer`: Channel buffer size (default: `1024`).
- `poll_timeout::Integer`: Event-loop poll timeout in ms (default: `0`).
- `max_body::Integer`: Maximum request body size in bytes (default: 1MB).
- `drain_timeout::Integer`: Graceful shutdown drain timeout (default: 5000ms).
- `request_timeout::Integer`: Per-request timeout in ms, 0 = disabled (default: `0`).
- `errors::Dict{Int,Response}`: Custom responses keyed by HTTP status code (`500`, `413`, `504`). See `fail!`.
"""
AsyncServer(::Type{T}; kwargs...) where {T <: StaticRouter} = AsyncServer(T(); kwargs...)
AsyncServer(::Type{T}, config::ServerConfig) where {T <: StaticRouter} = AsyncServer(T(), config)

function AsyncServer(router::AbstractRouter=Router();
                     workers::Integer=4,
                     nqueue::Integer=1024,
                     poll_timeout::Integer=0,
                     max_body::Integer=MAX_BODY,
                     drain_timeout::Integer=DRAIN_TIMEOUT,
                     request_timeout::Integer=0,
                     errors::Dict{Int,Response}=Dict{Int,Response}())
    c_handler = Mongoose._cfnasync(typeof(router))
    core = ServerCore(poll_timeout, router; max_body=max_body, drain_timeout=drain_timeout,
                      request_timeout=request_timeout, errors=errors, c_handler=c_handler)
    server = AsyncServer{typeof(router)}(
        core, Task[],
        Channel{Call}(nqueue), Channel{Reply}(nqueue),
        Dict{Int,MgConnection}(), Int(workers), Int(nqueue)
    )
    finalizer(_teardown!, server)
    return server
end

"""
    AsyncServer(router, config::ServerConfig)

Create an `AsyncServer` from a [`ServerConfig`](@ref) struct.
"""
function AsyncServer(router::AbstractRouter, config::ServerConfig)
    return AsyncServer(router;
        workers = config.workers,
        nqueue = config.nqueue,
        poll_timeout = config.poll_timeout,
        max_body = config.max_body,
        drain_timeout = config.drain_timeout,
        request_timeout = config.request_timeout,
        errors = config.errors
    )
end

function _init!(server::AsyncServer)
    server.core.manager = Manager()
    server.calls   = Channel{Call}(server.nqueue)
    server.replies = Channel{Reply}(server.nqueue)
    empty!(server.connections)
    empty!(server.core.clients)
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
        mg_mgr_poll(server.core.manager.ptr, server.core.poll_timeout)

        # Dispatch replies from workers back to C library
        local did_ws_send = false
        while isopen(server.replies) && isready(server.replies)
            res = take!(server.replies)
            conn = get(server.connections, res.id, nothing)
            if conn !== nothing
                if res.payload isa Response
                    _sendhttp!(conn, res.payload)
                    delete!(server.connections, res.id)
                else  # Message
                    try
                        _sendws!(conn, res.payload)
                        did_ws_send = true
                    catch e
                    @error "WebSocket send error" component="websocket" exception=(e, catch_backtrace())
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
    timeout = server.core.request_timeout
    try
        for req in server.calls     # blocks properly — no sleep needed
            if req.payload isa Request
                rid = _requestid(req.payload, server)
                res = try
                    if timeout > 0
                        _invoketimedhttp(server, req.payload, timeout)
                    else
                        _invokehttp(server, req.payload)
                    end
                catch e
                    @error "Handler error" component="http" uri=req.payload.uri exception=(e, catch_backtrace())
                    _handleerror(server, req.payload, e)
                end
                res = Response(res.status, _appendreqid(res.headers, rid), res.body)
                isopen(server.replies) && put!(server.replies, Tagged(req.id, res))
            else  # Intent
                res = _invokews(server, req)
                res !== nothing && isopen(server.replies) && put!(server.replies, res)
            end
        end
    catch e
        e isa InvalidStateException || rethrow(e)
    end
end

_haspending(server::AsyncServer) = isready(server.calls) || isready(server.replies)
