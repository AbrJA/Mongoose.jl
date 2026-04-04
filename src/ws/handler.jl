"""
    WebSocket event handling — upgrade, message dispatch, connection lifecycle.
"""

"""
    _handlewsmsg!(server, request) → Tagged{Message} or nothing
"""
function _handlewsmsg!(server::AbstractServer, request::Tagged{Intent})
    router = server.core.router
    return _routews(router, request)
end

@inline _routews(router::Router, request) = _dynws(router, request)
@inline _routews(router::StaticRouter, request) = _staticws(router, request)

function _staticws(static::StaticRouter, request::Tagged{Intent})
    endpoint = static_ws_upgrade(static, request.payload.uri)
    if endpoint !== nothing
        return _callep(endpoint, request)
    end
    return nothing
end

function _dynws(router::Router, request::Tagged{Intent})
    endpoint = get(router.ws_routes, request.payload.uri, nothing)
    if endpoint !== nothing
        return _callep(endpoint, request)
    end
    return nothing
end

# The dispatch helpers:
_tagws(id, res::Message)       = Tagged{Message}(id, res)
_tagws(id, res::String)          = _tagws(id, Message(res))
_tagws(id, res::Vector{UInt8})   = _tagws(id, Message(res))
_tagws(id, ::Nothing) = nothing

function _callep(endpoint::WsEndpoint, request::Tagged{Intent})
    try
        res = endpoint.on_message(request.payload.body)
        return _tagws(request.id, res)
    catch e
        @error "WebSocket on_message error" exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    _tryupgrade(server, conn, ev_data) → Bool
"""
function _tryupgrade(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    router = server.core.router
    message = MgHttpMessage(ev_data)
    uri = _tostring(message.uri)

    endpoint = _wsep(router, uri)
    if endpoint !== nothing
        _wsupgrade!(server, conn, ev_data, uri, endpoint, message)
        return true
    end

    return false
end

@inline _wsep(router::Router, uri) = get(router.ws_routes, uri, nothing)
@inline _wsep(router::StaticRouter, uri) = static_ws_upgrade(router, uri)

function _wsupgrade!(server, conn, ev_data, uri, endpoint, message)
    mg_ws_upgrade(conn, ev_data, C_NULL)
    server.core.ws_connections[Int(conn)] = uri
    if endpoint.on_open !== nothing
        req = Request(message)
        try
            endpoint.on_open(req)
        catch e
            @error "WebSocket on_open error" uri=uri exception=(e, catch_backtrace())
        end
    end
end

_wssend!(conn, data::String)        = mg_ws_send(conn, data, WS_OP_TEXT)
_wssend!(conn, data::Vector{UInt8}) = mg_ws_send(conn, data, WS_OP_BINARY)
_wssend!(conn, msg::Message)      = _wssend!(conn, msg.data)

# --- WS event handlers ---

# SyncServer: process WS message directly on event-loop thread
function _onevent!(server::SyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    ws_msg = _parsewsmsg(msg)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, "")
    tagged = Tagged(conn_id, Intent(ws_msg, uri))
    result = _handlewsmsg!(server, tagged)
    if result !== nothing
        _wssend!(conn, result.payload)
    end
    return
end

# AsyncServer: queue WS message to worker channels
function _onevent!(server::AsyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    ws_msg = _parsewsmsg(msg)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, "")
    server.connections[conn_id] = conn
    isopen(server.calls) && put!(server.calls, Tagged(conn_id, Intent(ws_msg, uri)))
    return
end

# Connection close — cleanup WS state
function _onevent!(server::AbstractServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    _closews!(server, conn)
    return
end

function _onevent!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    _closews!(server, conn)
    delete!(server.connections, Int(conn))
    return
end

"""
    _closews!(server, conn)
"""
function _closews!(server::AbstractServer, conn::MgConnection)
    conn_id = Int(conn)
    uri = get(server.core.ws_connections, conn_id, nothing)

    if uri !== nothing
        endpoint = _wsep(server.core.router, uri)
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
