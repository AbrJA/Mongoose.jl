mutable struct SyncServer{R <: Route} <: Server
    core::ServerCore{R}

    function SyncServer(; timeout::Integer=0)
        router = Router()
        server = new{typeof(router)}(ServerCore(timeout, router))
        finalizer(free_resources!, server)
        return server
    end
end

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

function run_event_loop(server::SyncServer)
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        yield()
    end
    return
end

# --- HTTP Event Handlers for SyncServer ---

function handle_event!(server::SyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    check_ws_upgrade(server, conn, ev_data) && return

    request = build_request(conn, ev_data)
    
    # In SyncServer, we handle it immediately on the same thread
    response = execute_http_handler(server, request)
    
    # Send reply
    mg_http_reply(conn, response.payload.status, response.payload.headers, response.payload.body)
    return
end

function handle_event!(server::SyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    return
end
