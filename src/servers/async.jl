"""
    AsyncServer — Multi-threaded server methods.
"""

function build_AsyncServer(http::AbstractHttpRouter, ws::AbstractWsRouter, c_handler::Ptr{Cvoid}, timeout::Integer, nworkers::Integer, nqueue::Integer, max_body_size::Integer, drain_timeout_ms::Integer)
    if c_handler == C_NULL
        c_handler = Mongoose.get_c_handler_async(typeof(http))
    end
    core = ServerCore(timeout, http, ws; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=c_handler)
    server = AsyncServer{typeof(http), typeof(ws)}(
        core, Task[],
        Channel{IdRequest{Request}}(nqueue), Channel{IdWsMessage}(nqueue),
        Channel{IdResponse{Response}}(nqueue), Channel{IdWsMessage}(nqueue),
        Dict{Int,MgConnection}(), nworkers, nqueue
    )
    finalizer(free_resources!, server)
    return server
end

function setup_resources!(server::AsyncServer)
    server.core.manager = Manager()
    return
end

function start_workers!(server::AsyncServer)
    empty!(server.workers)
    for i in 1:server.nworkers
        t = Threads.@spawn worker_loop(server)
        push!(server.workers, t)
    end
end

start_workers!(::AbstractServer) = nothing

function stop_workers!(server::AsyncServer)
    # Drain handles the cleanup of channels implicitly if workers check core.running
    for t in server.workers
        try wait(t) catch end
    end
    empty!(server.workers)
end

stop_workers!(::AbstractServer) = nothing

function run_event_loop(server::AsyncServer)
    server.core.running[] = true
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)

        # Dispatch responses from workers back to C library
        while isready(server.http_responses)
            id_res = take!(server.http_responses)
            conn = get(server.connections, id_res.id, nothing)
            if conn !== nothing
                send_response!(conn, id_res.payload)
                delete!(server.connections, id_res.id)
            end
        end

        while isready(server.ws_responses)
            id_res = take!(server.ws_responses)
            conn = get(server.connections, id_res.id, nothing)
            if conn !== nothing
                if id_res.payload isa WsTextMessage
                    mg_ws_send(conn, id_res.payload.data, WS_OP_TEXT)
                elseif id_res.payload isa WsBinaryMessage
                    mg_ws_send(conn, id_res.payload.data, WS_OP_BINARY)
                end
            end
        end
        yield()
    end
end

function worker_loop(server::AsyncServer)
    while server.core.running[]
        # Try HTTP
        if isready(server.http_requests)
            req = take!(server.http_requests)
            res = try
                _dispatch_http(server, req.payload)
            catch e
                @error "Handler error" exception=(e, catch_backtrace())
                Response(500, "Content-Type: text/plain\r\n", "500 Internal Server Error")
            end
            put!(server.http_responses, IdResponse(req.id, res))
        # Try WS
        elseif isready(server.ws_requests)
            req = take!(server.ws_requests)
            res = handle_ws_message!(server, req)
            if res !== nothing
                put!(server.ws_responses, res)
            end
        else
            sleep(0.0001)
        end
    end
end

_has_pending(server::AsyncServer) = isready(server.http_requests) || isready(server.http_responses) || isready(server.ws_requests) || isready(server.ws_responses)
