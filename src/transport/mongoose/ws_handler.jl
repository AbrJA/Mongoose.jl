"""
    WebSocket event handling — upgrade, message dispatch, connection lifecycle.

    New architecture: unified dispatch on AbstractServer, async branch via server.workers > 0.
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
    entry = get(server.ws_clients, conn_id, nothing)
    entry === nothing && return
    entry.last_active = time()
end

@inline function ws_register!(server::AbstractServer, conn_id::Int, uri::String)
    server.ws_clients[conn_id] = WsConn(uri, time(), false)
end

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

# --- WS Message ---

function on_ws_message(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    conn_id = Int(conn)
    ws_touch!(server, conn_id)

    if msg.data.len > server.ws_max_frame
        mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        entry = get(server.ws_clients, conn_id, nothing)
        entry !== nothing && (entry.closing = true)
        return
    end

    ws_msg = parse_ws_message(msg)
    uri = let e = get(server.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end

    if server.workers > 0
        # Async: queue to worker pool
        server.connections[conn_id] = conn
        if !try_enqueue!(server.calls, Tagged{Union{Request,Intent}}(conn_id, Intent(ws_msg, uri)), server.queuesize)
            @log_warn "WebSocket message dropped: worker queue full conn_id=$conn_id"
        end
    else
        # Sync: handle inline
        tagged = Tagged(conn_id, Intent(ws_msg, uri))
        result = invoke_ws(server, tagged)
        if result !== nothing
            send_ws_frame!(conn, result.payload)
        end
    end
end

# --- Connection Close ---

function on_connection_close(server::AbstractServer, conn::MgConnection, ::Ptr{Cvoid})
    conn_id = Int(conn)
    close_ws!(server, conn_id)
    server.workers > 0 && filter!(kv -> kv.second != conn, server.connections)
end

function close_ws!(server::AbstractServer, conn_id::Int)
    entry = pop!(server.ws_clients, conn_id, nothing)
    uri = entry === nothing ? nothing : entry.uri

    if uri !== nothing
        endpoint = ws_endpoint(server.router, uri)
        if endpoint !== nothing && endpoint.on_close !== nothing
            try
                endpoint.on_close()
            catch e
                @log_error "WebSocket on_close error uri=$uri" e catch_backtrace()
            end
        end
    end
end

# --- WS Idle Sweep ---

function ws_idle_sweep!(server::AbstractServer)
    now = time()
    timeout = Float64(server.ws_idle_timeout)
    to_close = Int[]
    for (id, entry) in server.ws_clients
        if (now - entry.last_active) > timeout
            push!(to_close, id)
        end
    end
    for id in to_close
        conn = get(server.connections, id, nothing)
        conn !== nothing && mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        close_ws!(server, id)
    end
end

# --- WS Dispatch ---

function invoke_ws(server::AbstractServer, request::Tagged{Intent})
    endpoint = ws_endpoint(server.router, request.payload.uri)
    endpoint === nothing && return nothing
    return call_ws_endpoint(endpoint, request)
end

tag_ws(id, res::Message)        = Tagged{Union{Response,StreamResponse,Message}}(id, res)
tag_ws(id, res::String)         = tag_ws(id, Message(res))
tag_ws(id, res::Vector{UInt8})  = tag_ws(id, Message(res))
tag_ws(id, ::Nothing)           = nothing

function call_ws_endpoint(endpoint::WsEndpoint, request::Tagged{Intent})
    try
        res = endpoint.on_message(request.payload.body)
        return tag_ws(request.id, res)
    catch e
        @log_error "WebSocket on_message error uri=$(request.payload.uri)" e catch_backtrace()
    end
    return nothing
end
