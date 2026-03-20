"""
    WebSocket event handling — upgrade, message dispatch, connection lifecycle.
"""

"""
    handle_ws_message!(server, request) → IdWsMessage or nothing
"""
function handle_ws_message!(server::AbstractServer, request::IdWsMessage)
    router = server.core.ws
    return _dispatch_ws_message(router, request)
end

@inline _dispatch_ws_message(router::WsRouter, request) = _handle_dynamic_ws_message(router, request)
@inline _dispatch_ws_message(router::StaticWsRouter, request) = _handle_static_ws_message(router, request)

function _handle_static_ws_message(static::StaticWsRouter, request::IdWsMessage)
    endpoint = static_ws_upgrade(static, request.uri)
    if endpoint !== nothing
        return _execute_ws_endpoint(endpoint, request)
    end
    return nothing
end

function _handle_dynamic_ws_message(router::WsRouter, request::IdWsMessage)
    endpoint = get(router.routes, request.uri, nothing)
    if endpoint !== nothing
        return _execute_ws_endpoint(endpoint, request)
    end
    return nothing
end

function _execute_ws_endpoint(endpoint::WsEndpoint, request::IdWsMessage)
    try
        res = endpoint.on_message(request.payload)
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
    return nothing
end

"""
    check_ws_upgrade(server, conn, ev_data) → Bool
"""
function check_ws_upgrade(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    router = server.core.ws
    message = MgHttpMessage(ev_data)
    uri = to_string(message.uri)

    endpoint = _get_ws_endpoint(router, uri)
    if endpoint !== nothing
        _do_ws_upgrade(server, conn, ev_data, uri, endpoint)
        return true
    end

    return false
end

@inline _get_ws_endpoint(router::WsRouter, uri) = get(router.routes, uri, nothing)
@inline _get_ws_endpoint(router::StaticWsRouter, uri) = static_ws_upgrade(router, uri)

function _do_ws_upgrade(server, conn, ev_data, uri, endpoint)
    mg_ws_upgrade(conn, ev_data, C_NULL)
    server.core.ws_connections[Int(conn)] = uri
    if endpoint.has_on_open
        req = Request(MgHttpMessage(ev_data))
        try endpoint.on_open(req) catch e end
    end
end

# --- WS event handlers ---

# SyncServer: process WS message directly on event-loop thread
function handle_event!(server::SyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    ws_msg = decode_ws_message(msg)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, "")
    id_msg = IdWsMessage(conn_id, ws_msg, uri)
    result = handle_ws_message!(server, id_msg)
    if result !== nothing
        if result.payload isa WsTextMessage
            mg_ws_send(conn, result.payload.data, WS_OP_TEXT)
        elseif result.payload isa WsBinaryMessage
            mg_ws_send(conn, result.payload.data, WS_OP_BINARY)
        end
    end
    return
end

# AsyncServer: queue WS message to worker channels
function handle_event!(server::AsyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    ws_msg = decode_ws_message(msg)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, "")
    server.connections[conn_id] = conn
    put!(server.ws_requests, IdWsMessage(conn_id, ws_msg, uri))
    return
end

# Connection close — cleanup WS state
function handle_event!(server::AbstractServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    return
end

function handle_event!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    delete!(server.connections, Int(conn))
    return
end

"""
    cleanup_ws_connection!(server, conn)
"""
function cleanup_ws_connection!(server::AbstractServer, conn::MgConnection)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, nothing)

    if uri !== nothing
        endpoint = _get_ws_endpoint(server.core.ws, uri)
        if endpoint !== nothing && endpoint.has_on_close
            try
                endpoint.on_close()
            catch e
                @error "WebSocket on_close error" exception = (e, catch_backtrace())
            end
        end
        delete!(server.core.ws_connections, conn_id)
    end
    return
end
