"""
    WebSocket event handling — upgrade, message dispatch, connection lifecycle.

    New architecture: uses named functions matching events.jl dispatch names:
    - on_ws_open, on_ws_message, on_ws_control, on_connection_close
"""

# --- Parse WebSocket message from FFI ---

function parse_ws_message(msg::MgWsMessage)::Message
    is_text = (msg.flags & 0x0F) == 1
    if msg.data.len > 0 && msg.data.buf != C_NULL
        if is_text
            return Message(unsafe_string(msg.data.buf, msg.data.len))
        else
            data = unsafe_wrap(Vector{UInt8}, msg.data.buf, Int(msg.data.len); own=false)
            return Message(copy(data))
        end
    end
    return is_text ? Message("") : Message(UInt8[])
end

# --- Connection tracking ---

@inline function ws_touch!(server::AbstractServer, conn_id::Int)
    entry = get(server.core.ws_clients, conn_id, nothing)
    entry === nothing && return
    entry.last_active = time()
end

@inline function ws_register!(server::AbstractServer, conn_id::Int, uri::String)
    server.core.ws_clients[conn_id] = WsConn(uri, time(), false)
end

@inline function ws_forget!(server::AbstractServer, conn_id::Int)
    pop!(server.core.ws_clients, conn_id, nothing)
end

# --- WebSocket endpoint lookup (Router version in router/trie.jl) ---

@inline ws_endpoint(router::StaticRouter, uri::String) = ws_static_lookup(router, uri)

# Static router stub — overridden by @router macro
ws_static_lookup(::StaticRouter, ::String) = nothing

# --- Upgrade ---

function ws_upgrade!(server, conn, ev_data, uri, endpoint, msg)
    if endpoint.on_open !== nothing
        req = adapt_request(msg)
        accepted = try
            result = endpoint.on_open(req)
            result !== false
        catch e
            @log_error "WebSocket on_open error uri=$uri" e catch_backtrace()
            true
        end
        if !accepted
            mg_http_reply(conn, 403, "", "Forbidden")
            return
        end
    end
    mg_ws_upgrade(conn, ev_data, C_NULL)
    ws_register!(server, Int(conn), uri)
end

function ws_upgrade!(server, conn, ev_data, uri, endpoint::StaticWsEndpoint{M,Nothing,C}, msg) where {M,C}
    mg_ws_upgrade(conn, ev_data, C_NULL)
    ws_register!(server, Int(conn), uri)
end

function ws_upgrade!(server, conn, ev_data, uri, endpoint::StaticWsEndpoint{M,O,C}, msg) where {M,O,C}
    req = adapt_request(msg)
    accepted = try
        result = endpoint.on_open(req)
        result !== false
    catch e
        @log_error "WebSocket on_open error uri=$uri" e catch_backtrace()
        true
    end
    if !accepted
        mg_http_reply(conn, 403, "", "Forbidden")
        return
    end
    mg_ws_upgrade(conn, ev_data, C_NULL)
    ws_register!(server, Int(conn), uri)
end

# --- WS Control Frames (Ping/Pong/Close) ---

function on_ws_control(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    op = msg.flags & 0x0F
    if op == WS_OP_PING || op == WS_OP_PONG
        ws_touch!(server, Int(conn))
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
end

# --- WS Message (Server — sync) ---

function on_ws_message(server::Server, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    conn_id = Int(conn)
    ws_touch!(server, conn_id)

    # Frame size limit
    if msg.data.len > server.core.ws_max_frame
        mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        let e = get(server.core.ws_clients, conn_id, nothing)
            e !== nothing && (e.closing = true)
        end
        return
    end

    ws_msg = parse_ws_message(msg)
    uri = let e = get(server.core.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end
    tagged = Tagged(conn_id, Intent(ws_msg, uri))
    result = invoke_ws(server, tagged)
    if result !== nothing
        send_ws_frame!(conn, result.payload)
    end
end

# --- WS Message (Async — queue to workers) ---

function on_ws_message(server::Async, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    conn_id = Int(conn)
    ws_touch!(server, conn_id)

    if msg.data.len > server.core.ws_max_frame
        mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        let e = get(server.core.ws_clients, conn_id, nothing)
            e !== nothing && (e.closing = true)
        end
        return
    end

    ws_msg = parse_ws_message(msg)
    uri = let e = get(server.core.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end
    server.connections[conn_id] = conn
    if !try_enqueue!(server.calls, Tagged{Union{Request,Intent}}(conn_id, Intent(ws_msg, uri)), server.nqueue)
        @log_warn "WebSocket message dropped: worker queue full conn_id=$conn_id"
    end
end

# --- Connection Close ---

function on_connection_close(server::AbstractServer, conn::MgConnection, ::Ptr{Cvoid})
    close_ws!(server, conn)
end

function on_connection_close(server::Async, conn::MgConnection, ::Ptr{Cvoid})
    close_ws!(server, conn)
    filter!(kv -> kv.second != conn, server.connections)
end

function close_ws!(server::AbstractServer, conn::MgConnection)
    conn_id = Int(conn)
    entry = pop!(server.core.ws_clients, conn_id, nothing)
    uri = entry === nothing ? nothing : entry.uri

    if uri !== nothing
        endpoint = ws_endpoint(server.core.router, uri)
        endpoint !== nothing && invoke_ws_close(endpoint, uri)
    end
end

function invoke_ws_close(endpoint::WsEndpoint, uri::String)
    if endpoint.on_close !== nothing
        try
            endpoint.on_close()
        catch e
            @log_error "WebSocket on_close error uri=$uri" e catch_backtrace()
        end
    end
end

invoke_ws_close(::StaticWsEndpoint{M,O,Nothing}, ::String) where {M,O} = nothing

function invoke_ws_close(endpoint::StaticWsEndpoint{M,O,C}, uri::String) where {M,O,C}
    try
        endpoint.on_close()
    catch e
        @log_error "WebSocket on_close error uri=$uri" e catch_backtrace()
    end
end

# --- WS Dispatch ---

function invoke_ws(server::AbstractServer, request::Tagged{Intent})
    return dispatch_ws(server.core.router, request)
end

function dispatch_ws(router::Router, request::Tagged{Intent})
    endpoint = get(router.ws_routes, request.payload.uri, nothing)
    endpoint !== nothing && return call_ws_endpoint(endpoint, request)
    return nothing
end

function dispatch_ws(router::StaticRouter, request::Tagged{Intent})
    endpoint = ws_static_lookup(router, request.payload.uri)
    endpoint !== nothing && return call_ws_endpoint(endpoint, request)
    return nothing
end

tag_ws(id, res::Message)        = Tagged{Union{Response,StreamResponse,Message}}(id, res)
tag_ws(id, res::String)         = tag_ws(id, Message(res))
tag_ws(id, res::Vector{UInt8})  = tag_ws(id, Message(res))
tag_ws(id, ::Nothing)           = nothing

function call_ws_endpoint(endpoint::AbstractWsEndpoint, request::Tagged{Intent})
    try
        res = endpoint.on_message(request.payload.body)
        return tag_ws(request.id, res)
    catch e
        @log_error "WebSocket on_message error uri=$(request.payload.uri)" e catch_backtrace()
    end
    return nothing
end

# --- Idle Sweep ---

"""
    ws_idle_sweep!(server) → Int

Close WebSocket connections idle longer than `ws_idle_timeout`.
"""
function ws_idle_sweep!(server::AbstractServer)
    clients = server.core.ws_clients
    isempty(clients) && return 0
    timeout_s = Float64(server.core.ws_idle_timeout)
    now_t = time()
    closed = 0
    for (conn_id, entry) in clients
        entry.closing && continue
        if (now_t - entry.last_active) > timeout_s
            conn = MgConnection(Ptr{Cvoid}(UInt(conn_id)))
            mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
            entry.closing = true
            closed += 1
        end
    end
    return closed
end
