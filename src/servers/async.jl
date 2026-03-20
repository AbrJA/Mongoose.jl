"""
    AsyncServer — multi-threaded asynchronous server with worker pool.
"""

"""
    AsyncServer{R, A} — Asynchronous HTTP/WebSocket server with background workers.
    Use `AsyncServer()` for dynamic routing (route! API).
    Use `AsyncServer(app)` for static routing (@router macro).

# Thread-Safety Invariant
`connections` and `ws_connections` are ONLY accessed from the event-loop thread.
"""
mutable struct AsyncServer{R <: AbstractRouter, S <: StaticRouter, W <: AbstractWsRouter} <: AbstractServer
    core::ServerCore{R, S, W}
    workers::Vector{Task}
    http_requests::Channel{IdRequest{Request}}
    ws_requests::Channel{IdWsMessage}
    http_responses::Channel{IdResponse{Response}}
    ws_responses::Channel{IdWsMessage}
    connections::Dict{Int,MgConnection}
    nworkers::Int
    nqueue::Int

    function AsyncServer{R, S, W}(core::ServerCore{R, S, W}, workers::Vector{Task},
                                  http_reqs::Channel{IdRequest{Request}}, ws_reqs::Channel{IdWsMessage},
                                  http_resps::Channel{IdResponse{Response}}, ws_resps::Channel{IdWsMessage},
                                  conns::Dict{Int,MgConnection}, nw::Int, nq::Int) where {R <: AbstractRouter, S <: StaticRouter, W <: AbstractWsRouter}
        server = new{R, S, W}(core, workers, http_reqs, ws_reqs, http_resps, ws_resps, conns, nw, nq)
        finalizer(free_resources!, server)
        return server
    end
end

function build_AsyncServer(static, ws_router::AbstractWsRouter, c_handler::Ptr{Cvoid}, timeout::Integer, nworkers::Integer, nqueue::Integer, max_body_size::Integer, drain_timeout_ms::Integer; router::DynamicRouter=DynamicRouter())
    if c_handler == C_NULL
        c_handler = Mongoose.get_c_handler_async(typeof(static))
    end
    core = ServerCore(timeout, router, static, ws_router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=c_handler)
    return AsyncServer{typeof(router), typeof(static), typeof(ws_router)}(
        core, Task[],
        Channel{IdRequest{Request}}(nqueue), Channel{IdWsMessage}(nqueue),
        Channel{IdResponse{Response}}(nqueue), Channel{IdWsMessage}(nqueue),
        Dict{Int,MgConnection}(), nworkers, nqueue
    )
end

function AsyncServer(static=NoStaticRouter(), ws_router::AbstractWsRouter=NoWsRouter(); c_handler::Ptr{Cvoid}=C_NULL, timeout::Integer=0, nworkers::Integer=1, nqueue::Integer=1024, max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS)
    return build_AsyncServer(static, ws_router, c_handler, timeout, nworkers, nqueue, max_body_size, drain_timeout_ms)
end

function setup_resources!(server::AsyncServer)
    server.core.manager = Manager()
    server.http_requests = Channel{IdRequest{Request}}(server.nqueue)
    server.ws_requests = Channel{IdWsMessage}(server.nqueue)
    server.http_responses = Channel{IdResponse{Response}}(server.nqueue)
    server.ws_responses = Channel{IdWsMessage}(server.nqueue)
    server.connections = Dict{Int,MgConnection}()
    return
end

function worker_loop(server::AsyncServer, worker_index::Integer, router::AbstractRouter)
    @info "Worker thread $worker_index started on thread $(Threads.threadid())"
    while server.core.running[]
        try
            processed = false

            if isready(server.http_requests)
                request = take!(server.http_requests)
                response = execute_http_handler(server, request)
                put!(server.http_responses, response)
                processed = true
            end

            if isready(server.ws_requests)
                request = take!(server.ws_requests)
                response = handle_ws_message!(server, request)
                if response !== nothing
                    put!(server.ws_responses, response)
                end
                processed = true
            end

            # Only pause when no work was done — avoids busy-spin while
            # keeping both HTTP and WS channels responsive
            processed || sleep(0.0001)
        catch e
            if !server.core.running[]
                break
            elseif e isa InvalidStateException
                break
            else
                @error "Worker thread error: $e" exception=(e, catch_backtrace())
            end
        end
    end
    @info "Worker thread $worker_index finished"
    return
end

function start_workers!(server::AsyncServer)
    resize!(server.workers, server.nworkers)
    for i in eachindex(server.workers)
        server.workers[i] = Threads.@spawn worker_loop(server, i, server.core.router)
    end
    return
end

function stop_workers!(server::AsyncServer)
    close(server.http_requests)
    close(server.ws_requests)
    for worker in server.workers
        try wait(worker) catch e end
    end
    return
end

function process_responses!(server::AsyncServer)
    while isready(server.http_responses)
        response = take!(server.http_responses)
        conn = get(server.connections, response.id, nothing)
        conn === nothing && continue
        if response.payload isa PreRenderedResponse
            mg_send(conn, response.payload.bytes)
        else
            mg_http_reply(conn, response.payload.status, response.payload.headers, response.payload.body)
        end
    end
    while isready(server.ws_responses)
        response = take!(server.ws_responses)
        conn = get(server.connections, response.id, nothing)
        conn === nothing && continue
        if response.payload isa WsTextMessage
            mg_ws_send(conn, response.payload.data, WS_OP_TEXT)
        elseif response.payload isa WsBinaryMessage
            mg_ws_send(conn, response.payload.data, WS_OP_BINARY)
        end
    end
    return
end

function run_event_loop(server::AsyncServer)
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        process_responses!(server)
        server.core.timeout == 0 && yield()
    end
    return
end

function cleanup_connection!(server::AsyncServer, conn::MgConnection)
    delete!(server.connections, Int(conn))
    return
end

_has_pending(server::AsyncServer) = isready(server.http_requests) || isready(server.http_responses) || isready(server.ws_requests) || isready(server.ws_responses)

function handle_event!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    check_ws_upgrade(server, conn, ev_data) && return
    request = build_request(conn, ev_data)
    server.connections[request.id] = conn
    put!(server.http_requests, request)
    return
end

function handle_event!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    cleanup_connection!(server, conn)
    return
end
