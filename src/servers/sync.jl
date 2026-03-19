"""
    SyncServer — single-threaded synchronous server.
"""

"""
    SyncServer{R, A} — Synchronous HTTP/WebSocket server.
    Use `SyncServer()` for dynamic routing (route! API).
    Use `SyncServer(app)` for static routing (@routes macro).
"""
mutable struct SyncServer{R <: Route, A} <: Server
    core::ServerCore{R, A}

    function SyncServer(; timeout::Integer=0, max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS)
        router = Router()
        handler = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
        core = ServerCore(timeout, router, NoApp(); max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=handler)
        server = new{typeof(router), NoApp}(core)
        finalizer(free_resources!, server)
        return server
    end

    function SyncServer(app::A; c_handler::Ptr{Cvoid}, timeout::Integer=0, max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS) where {A <: AbstractApp}
        router = Router()
        core = ServerCore(timeout, router, app; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=c_handler)
        server = new{typeof(router), A}(core)
        finalizer(free_resources!, server)
        return server
    end
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
