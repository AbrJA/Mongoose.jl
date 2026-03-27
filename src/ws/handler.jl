"""
    WebSocket event handling — upgrade, message dispatch, connection lifecycle.
"""

"""
    handle_ws_message!(server, request) → Tagged{WsMessage} or nothing
"""
function handle_ws_message!(server::AbstractServer, request::Tagged{WsRouted})
    router = server.core.router
    return _dispatch_ws_message(router, request)
end

@inline _dispatch_ws_message(router::Router, request) = _handle_dynamic_ws_message(router, request)
@inline _dispatch_ws_message(router::StaticRouter, request) = _handle_static_ws_message(router, request)

function _handle_static_ws_message(static::StaticRouter, request::Tagged{WsRouted})
    endpoint = static_ws_upgrade(static, request.payload.uri)
    if endpoint !== nothing
        return _execute_ws_endpoint(endpoint, request)
    end
    return nothing
end

function _handle_dynamic_ws_message(router::Router, request::Tagged{WsRouted})
    endpoint = get(router.ws_routes, request.payload.uri, nothing)
    if endpoint !== nothing
        return _execute_ws_endpoint(endpoint, request)
    end
    return nothing
end

# The dispatch helpers:
_format_ws_response(id, res::WsMessage) = Tagged{WsMessage}(id, res)
_format_ws_response(id, res::String) = Tagged{WsMessage}(id, WsMessage(Text, res))
_format_ws_response(id, res::Vector{UInt8}) = Tagged{WsMessage}(id, WsMessage(Binary, res))
_format_ws_response(id, ::Nothing) = nothing

function _execute_ws_endpoint(endpoint::WsEndpoint, request::Tagged{WsRouted})
    try
        res = endpoint.on_message(request.payload.message)
        return _format_ws_response(request.id, res)
    catch e
        @error "WebSocket on_message error" exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    check_ws_upgrade(server, conn, ev_data) → Bool
"""
function check_ws_upgrade(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    router = server.core.router
    message = MgHttpMessage(ev_data)
    uri = to_string(message.uri)

    endpoint = _get_ws_endpoint(router, uri)
    if endpoint !== nothing
        _ws_upgrade!(server, conn, ev_data, uri, endpoint, message)
        return true
    end

    return false
end

@inline _get_ws_endpoint(router::Router, uri) = get(router.ws_routes, uri, nothing)
@inline _get_ws_endpoint(router::StaticRouter, uri) = static_ws_upgrade(router, uri)

function _ws_upgrade!(server, conn, ev_data, uri, endpoint, message)
    mg_ws_upgrade(conn, ev_data, C_NULL)
    server.core.ws_connections[Int(conn)] = uri
    if endpoint.on_open !== nothing
        req = Request(message)
        try
            endpoint.on_open(req)
        catch e
        end
    end
end

_send_ws_native(conn, msg::WsMessage{Text}) = mg_ws_send(conn, msg.data, WS_OP_TEXT)
_send_ws_native(conn, msg::WsMessage{Binary}) = mg_ws_send(conn, msg.data, WS_OP_BINARY)

# --- WS event handlers ---

# SyncServer: process WS message directly on event-loop thread
function _onevent!(server::SyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    ws_msg = decode_ws_message(msg)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, "")
    tagged = Tagged(conn_id, WsRouted(ws_msg, uri))
    result = handle_ws_message!(server, tagged)
    if result !== nothing
        _send_ws_native(conn, result.payload)
    end
    return
end

# AsyncServer: queue WS message to worker channels
function _onevent!(server::AsyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    ws_msg = decode_ws_message(msg)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, "")
    server.connections[conn_id] = conn
    isopen(server.ws_requests) && put!(server.ws_requests, Tagged(conn_id, WsRouted(ws_msg, uri)))
    return
end

# Connection close — cleanup WS state
function _onevent!(server::AbstractServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    return
end

function _onevent!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
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
        endpoint = _get_ws_endpoint(server.core.router, uri)
        if endpoint !== nothing && endpoint.on_close !== nothing
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
