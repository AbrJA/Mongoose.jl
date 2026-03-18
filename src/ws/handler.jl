"""
    WebSocket event handling — upgrade, message dispatch, connection lifecycle.
"""

"""
    handle_ws_message!(server, request) → IdWsMessage or nothing

Dispatch a WebSocket message to the appropriate handler registered via `ws!`.
Returns a response message to be sent back, or `nothing` to send nothing.
"""
function handle_ws_message!(server::Server, request::IdWsMessage)
    server.core.ws_router isa NoWsRouter && return nothing
    return _handle_dynamic_ws_message!(server, request)
end

function _handle_dynamic_ws_message!(server::Server, request::IdWsMessage)
    handlers = get_ws_handlers(server, request.uri)
    if handlers !== nothing
        try
            res = handlers.on_message(request.payload)
            if res isa WsTextMessage
                return IdWsMessage(request.id, res, request.uri)
            elseif res isa WsBinaryMessage
                return IdWsMessage(request.id, res, request.uri)
            elseif res isa String
                return IdWsMessage(request.id, WsTextMessage(res), request.uri)
            elseif res isa Vector{UInt8}
                return IdWsMessage(request.id, WsBinaryMessage(res), request.uri)
            end
        catch e
            @error "WebSocket on_message error" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

"""
    get_ws_handlers(server, uri) → WsHandlers or nothing

Look up the WebSocket handlers for a given URI path.
"""
function get_ws_handlers(server::Server, uri::String)
    server.core.ws_router isa NoWsRouter && return nothing
    return get(server.core.ws_router.routes, uri, nothing)
end

"""
    check_ws_upgrade(server, conn, ev_data) → Bool

Check if an incoming HTTP request is a WebSocket upgrade.
If a matching WS route exists, performs the upgrade and calls `on_open`.
Returns `true` if the request was intercepted as a WS upgrade.
"""
function check_ws_upgrade(server::Server, conn::MgConnection, ev_data::Ptr{Cvoid})
    server.core.ws_router isa NoWsRouter && return false
    return _check_dynamic_ws_upgrade(server, conn, ev_data)
end

function _check_dynamic_ws_upgrade(server::Server, conn::MgConnection, ev_data::Ptr{Cvoid})
    message = MgHttpMessage(ev_data)
    uri = to_string(message.uri)

    if haskey(server.core.ws_router.routes, uri)
        # Build request from the already-parsed message (avoid double parse)
        req = build_request(conn, message)

        # Accept the WebSocket upgrade
        mg_ws_upgrade(conn, ev_data, C_NULL)

        server.core.ws_connections[Int(conn)] = uri

        handlers = server.core.ws_router.routes[uri]
        if handlers.on_open !== nothing
            try
                handlers.on_open(req.payload)
            catch e
                @error "WebSocket on_open error" exception = (e, catch_backtrace())
            end
        end
        return true
    end
    return false
end

# --- WebSocket event handlers for AsyncServer ---

"""
    handle_event!(server::AsyncServer, ::Val{MG_EV_WS_MSG}, conn, ev_data)

Handle WebSocket message on AsyncServer — decode and enqueue for worker processing.
"""
function handle_event!(server::AsyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    server.connections[Int(conn)] = conn
    msg = decode_ws_message(MgWsMessage(ev_data))
    uri = get(server.core.ws_connections, Int(conn), "")
    req = IdWsMessage(Int(conn), msg, uri)
    put!(server.ws_requests, req)
    return
end

# --- WebSocket event handlers for SyncServer ---

"""
    handle_event!(server::SyncServer, ::Val{MG_EV_WS_MSG}, conn, ev_data)

Handle WebSocket message on SyncServer — process inline and respond immediately.
"""
function handle_event!(server::SyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = decode_ws_message(MgWsMessage(ev_data))
    uri = get(server.core.ws_connections, Int(conn), "")
    req = IdWsMessage(Int(conn), msg, uri)

    res = handle_ws_message!(server, req)
    if res isa IdWsMessage
        if res.payload isa WsTextMessage
            mg_ws_send(conn, res.payload.data, WS_OP_TEXT)
        elseif res.payload isa WsBinaryMessage
            mg_ws_send(conn, res.payload.data, WS_OP_BINARY)
        end
    end
    return
end

"""
    handle_event!(server::Server, ::Val{MG_EV_WS_CTL}, conn, ev_data)

Handle WebSocket control frames (ping/pong/close). Largely handled by Mongoose C internally.
"""
function handle_event!(server::Server, ::Val{MG_EV_WS_CTL}, conn::MgConnection, ev_data::Ptr{Cvoid})
    return
end

"""
    cleanup_ws_connection!(server, conn)

Clean up WebSocket state when a connection closes. Calls `on_close` if registered.
"""
function cleanup_ws_connection!(server::Server, conn::MgConnection)
    server.core.ws_router isa NoWsRouter && return
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, nothing)
    
    if uri !== nothing
        handlers = get_ws_handlers(server, uri)
        if handlers !== nothing && handlers.on_close !== nothing
            try
                handlers.on_close()
            catch e
                @error "WebSocket on_close error" exception = (e, catch_backtrace())
            end
        end
        delete!(server.core.ws_connections, conn_id)
    end
    return
end

"""
    send_ws(conn, message::String) — Send a text WebSocket message.
"""
function send_ws(conn::MgConnection, message::String)
    mg_ws_send(conn, message, WS_OP_TEXT)
end

"""
    send_ws(conn, payload::Vector{UInt8}) — Send a binary WebSocket message.
"""
function send_ws(conn::MgConnection, payload::Vector{UInt8})
    mg_ws_send(conn, payload, WS_OP_BINARY)
end
