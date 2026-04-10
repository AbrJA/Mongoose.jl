"""
    WebSocket event handling — upgrade, message dispatch, connection lifecycle.
"""

# Touch: update last_active in-place — no allocation, no write barrier (Float64 field).
# Safe to call inside C callbacks.
@inline function _wstouch!(server::AbstractServer, conn_id::Int)
    entry = get(server.core.ws_clients, conn_id, nothing)
    entry === nothing && return
    entry.last_active = time()
end

# Register a new connection (called once, right after mg_ws_upgrade).
@inline function _wsregister!(server::AbstractServer, conn_id::Int, uri::String)
    server.core.ws_clients[conn_id] = WsConn(uri, time())
end

# Forget: remove on close (idempotent — fine if already absent).
@inline function _wsforget!(server::AbstractServer, conn_id::Int)
    pop!(server.core.ws_clients, conn_id, nothing)
end

"""
    _invokews(server, request) → Tagged{Message} or nothing
"""
function _invokews(server::AbstractServer, request::Tagged{Intent})
    return _dispatchws(server.core.router, request)
end

function _dispatchws(router::Router, request::Tagged{Intent})
    endpoint = get(router.ws_routes, request.payload.uri, nothing)
    endpoint !== nothing && return _callwsep(endpoint, request)
    return nothing
end

function _dispatchws(router::StaticRouter, request::Tagged{Intent})
    endpoint = _wsupgrade(router, request.payload.uri)
    endpoint !== nothing && return _callwsep(endpoint, request)
    return nothing
end

_tagws(id, res::Message)        = Tagged{Message}(id, res)
_tagws(id, res::String)         = _tagws(id, Message(res))
_tagws(id, res::Vector{UInt8})  = _tagws(id, Message(res))
_tagws(id, ::Nothing)           = nothing

function _callwsep(endpoint::WsEndpoint, request::Tagged{Intent})
    try
        res = endpoint.on_message(request.payload.body)
        return _tagws(request.id, res)
    catch e
        _log_error("WebSocket on_message error component=websocket uri=$(request.payload.uri)", e, catch_backtrace())
    end
    return nothing
end

# --- WS route lookup and dispatch helpers ---
@inline _wsep(router::Router, uri) = get(router.ws_routes, uri, nothing)
@inline _wsep(router::StaticRouter, uri) = _wsupgrade(router, uri)

function _wsupgrade!(server, conn, ev_data, uri, endpoint, message)
    # Upgrade rejection: if on_open returns `false`, reject with 403
    if endpoint.on_open !== nothing
        req = Request(message)
        accepted = try
            result = endpoint.on_open(req)
            result !== false  # anything other than literal `false` means accept
        catch e
            _log_error("WebSocket on_open error component=websocket uri=$uri", e, catch_backtrace())
            true  # accept by default if on_open throws
        end
        if !accepted
            mg_http_reply(conn, 403, "", "Forbidden")
            return
        end
    end
    mg_ws_upgrade(conn, ev_data, C_NULL)
    _wsregister!(server, Int(conn), uri)
end

_sendws!(conn, data::String)        = mg_ws_send(conn, data, WS_OP_TEXT)
_sendws!(conn, data::Vector{UInt8}) = mg_ws_send(conn, data, WS_OP_BINARY)
_sendws!(conn, msg::Message)        = _sendws!(conn, msg.data)

# --- WS control frame handler (close / ping / pong) ---

"""
    _onevent!(server, ::Val{MG_EV_WS_CTL}, conn, ev_data)

Handle WebSocket control frames per RFC 6455:
- **Close (0x8)**: Echo the close payload back (status code + optional reason)
  to complete the closing handshake. Mongoose marks the connection for closing
  on the next poll cycle.
- **Ping (0x9)**: Reply with a Pong carrying the same payload (§5.5.3).
- **Pong (0xA)**: Received as a keep-alive ack — no action needed.
"""
function _onevent!(server::AbstractServer, ::Val{MG_EV_WS_CTL}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    op = msg.flags & 0x0F
    # Ping and Pong indicate the client is alive — update idle timestamp
    if op == WS_OP_PING || op == WS_OP_PONG
        _wstouch!(server, Int(conn))
    end
    if op == WS_OP_CLOSE || op == WS_OP_PING
        reply_op = op == WS_OP_CLOSE ? WS_OP_CLOSE : WS_OP_PONG
        if msg.data.len > 0 && msg.data.buf != C_NULL
            payload = copy(unsafe_wrap(Array, msg.data.buf, Int(msg.data.len)))
            mg_ws_send(conn, payload, reply_op)
        else
            mg_ws_send(conn, UInt8[], reply_op)
        end
    end
    return
end

# --- WS event handlers ---

# Server: process WS message directly on event-loop thread
function _onevent!(server::Server, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    conn_id = Int(conn)
    _wstouch!(server, conn_id)

    # Frame size limit (reuses max_body from HTTP config)
    if msg.data.len > server.core.max_body
        mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        return
    end

    ws_msg = _parsewsmsg(msg)
    uri = let e = get(server.core.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end
    tagged = Tagged(conn_id, Intent(ws_msg, uri))
    result = _invokews(server, tagged)
    if result !== nothing
        _sendws!(conn, result.payload)
    end
    return
end

# Async: queue WS message to worker tasks
function _onevent!(server::Async, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    conn_id = Int(conn)
    _wstouch!(server, conn_id)

    # Frame size limit (reuses max_body from HTTP config)
    if msg.data.len > server.core.max_body
        mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        return
    end

    ws_msg = _parsewsmsg(msg)
    uri = let e = get(server.core.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end
    server.connections[conn_id] = conn
    if !_tryput!(server.calls, Tagged(conn_id, Intent(ws_msg, uri)), server.nqueue)
        _log_warn("WebSocket message dropped: worker queue full component=websocket conn_id=$conn_id")
    end
    return
end

# Connection close — cleanup WS state
function _onevent!(server::AbstractServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    _closews!(server, conn)
    return
end

function _onevent!(server::Async, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    _closews!(server, conn)
    # Remove ALL entries referencing this closed connection (both request-ID
    # and WS-keyed entries) to prevent writing to a stale/recycled pointer.
    filter!(kv -> kv.second != conn, server.connections)
    return
end

"""
    _closews!(server, conn)

Clean up WebSocket state when a connection closes: fire `on_close` if registered,
then remove the connection URI from `clients`.
"""
function _closews!(server::AbstractServer, conn::MgConnection)
    conn_id = Int(conn)
    entry = pop!(server.core.ws_clients, conn_id, nothing)
    uri = entry === nothing ? nothing : entry.uri

    if uri !== nothing
        endpoint = _wsep(server.core.router, uri)
        if endpoint !== nothing && endpoint.on_close !== nothing
            try
                endpoint.on_close()
            catch e
                _log_error("WebSocket on_close error component=websocket uri=$uri", e, catch_backtrace())
            end
        end
    end
    return
end

"""
    _wsidlesweep!(server) → Int

Close WebSocket connections that have been idle longer than
`server.core.ws_idle_timeout` seconds. Called periodically from the event
loop. Removes the entry immediately after sending the close frame so
repeated sweeps cannot fire a second close to the same connection.
Returns the number of connections closed.
"""
function _wsidlesweep!(server::AbstractServer)
    clients = server.core.ws_clients
    isempty(clients) && return 0
    timeout_s = Float64(server.core.ws_idle_timeout)
    now_t = time()
    closed = 0
    for (conn_id, entry) in collect(clients)
        if (now_t - entry.last_active) > timeout_s
            conn = MgConnection(Ptr{Cvoid}(UInt(conn_id)))
            mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
            # Remove immediately — prevents duplicate close frames on future sweeps.
            pop!(clients, conn_id, nothing)
            closed += 1
        end
    end
    return closed
end
