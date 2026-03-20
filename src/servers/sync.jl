"""
    SyncServer — single-threaded synchronous server.
"""

"""
    SyncServer{R, A} — Synchronous HTTP/WebSocket server.
    Use `SyncServer()` for dynamic routing (route! API).
    Use `SyncServer(app)` for static routing (@router macro).
"""
mutable struct SyncServer{R <: AbstractRouter, S <: StaticRouter, W <: AbstractWsRouter} <: AbstractServer
    core::ServerCore{R, S, W}

    function SyncServer{R, S, W}(core::ServerCore{R, S, W}) where {R <: AbstractRouter, S <: StaticRouter, W <: AbstractWsRouter}
        server = new{R, S, W}(core)
        finalizer(free_resources!, server)
        return server
    end
end

function build_SyncServer(static, ws_router::AbstractWsRouter, c_handler::Ptr{Cvoid}, timeout::Integer, max_body_size::Integer, drain_timeout_ms::Integer; router::DynamicRouter=DynamicRouter())
    if c_handler == C_NULL
        c_handler = Mongoose.get_c_handler_sync(typeof(static))
    end
    core = ServerCore(timeout, router, static, ws_router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=c_handler)
    return SyncServer{typeof(router), typeof(static), typeof(ws_router)}(core)
end

function SyncServer(static=NoStaticRouter(), ws_router::AbstractWsRouter=NoWsRouter(); c_handler::Ptr{Cvoid}=C_NULL, timeout::Integer=0, max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS)
    return build_SyncServer(static, ws_router, c_handler, timeout, max_body_size, drain_timeout_ms)
end

function setup_resources!(server::SyncServer)
    server.core.manager = Manager()
    return
end

start_workers!(::SyncServer) = nothing
stop_workers!(::SyncServer) = nothing

function run_event_loop(server::SyncServer)
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        yield()
    end
    return
end

function handle_event!(server::SyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    check_ws_upgrade(server, conn, ev_data) && return

    request = build_view_request(conn, ev_data)
    response = execute_http_handler(server, request)

    if response.payload isa PreRenderedResponse
        mg_send(conn, response.payload.bytes)
    else
        mg_http_reply(conn, response.payload.status, response.payload.headers, response.payload.body)
    end
    return
end

function handle_event!(server::SyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    return
end
