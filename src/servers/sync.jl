"""
    SyncServer — single-threaded synchronous server.
    Handles requests directly on the event loop thread for minimal latency.
"""

"""
    SyncServer{R} — A synchronous HTTP/WebSocket server.
    Processes requests inline during `mg_mgr_poll`, one at a time.
    Best for: simple scripts, low-latency single-task workloads, or when
    full control over the execution flow is needed.
"""
mutable struct SyncServer{R <: Route} <: Server
    core::ServerCore{R}

    function SyncServer(; timeout::Integer=0, max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS)
        router = Router()
        server = new{typeof(router)}(ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms))
        finalizer(free_resources!, server)
        return server
    end
end

"""
    setup_resources!(server::SyncServer) — Initialize C manager and event handler.
"""
function setup_resources!(server::SyncServer)
    server.core.manager = Manager()
    server.core.handler = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    return
end

function start_workers!(::SyncServer)
    return
end

function stop_workers!(::SyncServer)
    return
end

"""
    run_event_loop(server::SyncServer) — Main poll loop for synchronous server.
"""
function run_event_loop(server::SyncServer)
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        yield()
    end
    return
end

# --- HTTP Event Handlers for SyncServer ---

"""
    handle_event!(server::SyncServer, ::Val{MG_EV_HTTP_MSG}, conn, ev_data)

Handle an incoming HTTP message on a SyncServer — processes immediately on the event thread.
"""
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

"""
    handle_event!(server::SyncServer, ::Val{MG_EV_CLOSE}, conn, ev_data)

Handle connection close on SyncServer — clean up WebSocket state.
"""
function handle_event!(server::SyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    return
end
