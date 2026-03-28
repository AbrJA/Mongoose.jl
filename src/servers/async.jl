"""
    AsyncServer — Multi-threaded server methods.
"""

"""
    AsyncServer(router=Router(); workers=4, nqueue=1024, timeout=0, max_body_size, drain_timeout_ms)

Create a multi-threaded server with `workers` background tasks.
Not compatible with `juliac --trim=safe`.
"""
AsyncServer(::Type{T}; kwargs...) where {T <: StaticRouter} = AsyncServer(T(); kwargs...)

function AsyncServer(router::AbstractRouter=Router();
                     workers::Integer=4,
                     nqueue::Integer=1024,
                     timeout::Integer=0,
                     max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                     drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS)
    c_handler = Mongoose._cfnasync(typeof(router))
    core = ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=c_handler)
    server = AsyncServer{typeof(router)}(
        core, Task[],
        Channel{Tagged{Request}}(nqueue), Channel{Tagged{WsEnvelope}}(nqueue),
        Channel{Tagged{Response}}(nqueue), Channel{Tagged{WsMessage}}(nqueue),
        Dict{Int,MgConnection}(), Int(workers), Int(nqueue)
    )
    finalizer(_teardown!, server)
    return server
end

function _init!(server::AsyncServer)
   server.core.manager = Manager()
   server.http_requests  = Channel{Tagged{Request}}(server.nqueue)
   server.ws_requests    = Channel{Tagged{WsEnvelope}}(server.nqueue)
   server.http_responses = Channel{Tagged{Response}}(server.nqueue)
   server.ws_responses   = Channel{Tagged{WsMessage}}(server.nqueue)
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
    close(server.http_requests)
    close(server.ws_requests)
    close(server.http_responses)
    close(server.ws_responses)

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

        # Dispatch responses from workers back to C library
        while isopen(server.http_responses) && isready(server.http_responses)
            id_res = take!(server.http_responses)
            conn = get(server.connections, id_res.id, nothing)
            if conn !== nothing
                _send!(conn, id_res.payload)
                delete!(server.connections, id_res.id)
            end
        end

        # Dispatch WS responses — flush immediately after sending
        local did_ws_send = false
        while isopen(server.ws_responses) && isready(server.ws_responses)
            id_res = take!(server.ws_responses)
            conn = get(server.connections, id_res.id, nothing)
            if conn !== nothing
                try
                    _wssend!(conn, id_res.payload)
                    did_ws_send = true
                catch e
                    @error "WebSocket send error" exception=(e, catch_backtrace())
                end
            end
        end
        # Extra poll to flush mg_ws_send buffers immediately
        did_ws_send && mg_mgr_poll(server.core.manager.ptr, 1)
        yield()
    end
end

function _workloop(server::AsyncServer)
    try
        while server.core.running[]
            # Try HTTP
            if isready(server.http_requests)
                req = take!(server.http_requests)
                res = try
                    _servehttp(server, req.payload)
                catch e
                    @error "Handler error" exception=(e, catch_backtrace())
                    Response(500, ContentType.text, "500 Internal Server Error")
                end
                isopen(server.http_responses) && put!(server.http_responses, Tagged(req.id, res))
            # Try WS
            elseif isready(server.ws_requests)
                req = take!(server.ws_requests)
                res = _handlewsmsg!(server, req)
                if res !== nothing
                    isopen(server.ws_responses) && put!(server.ws_responses, res)
                end
            else
                sleep(0.001)
            end
        end
    catch e
        e isa InvalidStateException || rethrow(e)
    end
end

_haspending(server::AsyncServer) = isready(server.http_requests) || isready(server.http_responses) || isready(server.ws_requests) || isready(server.ws_responses)
