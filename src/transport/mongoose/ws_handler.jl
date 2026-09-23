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
    lock(server.runtime.ws_lock) do
        entry = get(server.runtime.ws_clients, conn_id, nothing)
        entry === nothing && return
        entry.last_active = time()
    end
end

@inline function ws_register!(server::AbstractServer, conn_id::Int, uri::String, conn::MgConnection)
    lock(server.runtime.ws_lock) do
        server.runtime.ws_clients[conn_id] = WsConn(uri, time(), false)
    end
    # Track the connection so idle sweeps can send close frames in sync mode
    # too (async mode also inserts it, but the mapping is mode-agnostic now).
    server.runtime.connections[conn_id] = conn
end

# --- Upgrade ---

function ws_upgrade!(server, conn, ev_data, uri, endpoint, msg)
    headers = parse_headers(msg)
    # Only a real upgrade handshake may run user hooks or register a client;
    # `mg_ws_upgrade` replies 426 to anything else.
    is_upgrade = occursin("websocket", lowercase(get(headers, "upgrade", ""))) &&
                 occursin("upgrade", lowercase(get(headers, "connection", ""))) &&
                 haskey(headers, "sec-websocket-key")
    if !is_upgrade
        mg_ws_upgrade(conn, ev_data, C_NULL)
        return
    end

    if !isempty(endpoint.allowed_origins)
        origin = get(headers, "origin", "")
        if !any(o -> o == origin, endpoint.allowed_origins)
            mg_http_reply(conn, 403, "", "Forbidden")
            return
        end
    end
    if endpoint.on_open !== nothing
        req = adapt_request(msg; remote_addr=remote_addr_of(conn))
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
    ws_register!(server, Int(conn), uri, conn)
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

    if msg.data.len > server.config.ws_max_frame_bytes
        mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        lock(server.runtime.ws_lock) do
            entry = get(server.runtime.ws_clients, conn_id, nothing)
            entry !== nothing && (entry.closing = true)
        end
        return
    end

    ws_msg = parse_ws_message(msg)
    uri = lock(server.runtime.ws_lock) do
        let e = get(server.runtime.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end
    end

    if server.executor isa AsyncExecutor
        # Async: submit the dispatch as a job to the worker pool
        exec = server.executor
        server.runtime.connections[conn_id] = conn
        tagged = Tagged(conn_id, Intent(ws_msg, uri))
        if !submit!(exec, () -> invoke_ws(server, tagged))
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
    filter!(kv -> kv.second != conn, server.runtime.connections)
    # Abort any active stream on this connection: unblocks the producer.
    st = pop!(server.runtime.streams, conn_id, nothing)
    st !== nothing && close(st.channel)
end

function close_ws!(server::AbstractServer, conn_id::Int)
    entry = lock(server.runtime.ws_lock) do
        pop!(server.runtime.ws_clients, conn_id, nothing)
    end
    uri = entry === nothing ? nothing : entry.uri

    if uri !== nothing
        endpoint = getwsendpoint(server.router, uri)
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
    # `last_active` is `time()` (seconds); the config is milliseconds.
    timeout = server.config.ws_idle_timeout_ms / 1000.0
    to_close = lock(server.runtime.ws_lock) do
        to_close = Int[]
        for (id, entry) in server.runtime.ws_clients
            if (now - entry.last_active) > timeout
                entry.closing = true
                push!(to_close, id)
            end
        end
        return to_close
    end
    for id in to_close
        conn = get(server.runtime.connections, id, nothing)
        conn === nothing && continue
        # Queue a Close frame, then drop the socket even if the peer never
        # answers — mg_close_conn flushes pending output before closing.
        mg_ws_send(conn, UInt8[], WS_OP_CLOSE)
        mg_close_conn(conn)
    end
end

"""
    ws_send_all(server, path, data)

Server-initiated WebSocket push: enqueue a text frame for every open client of
`path` (async executors only — the frame is routed through the same reply
queue the worker pool uses, so it is sent on the poll/callback thread and is
safe to call from any task). Idle/closed clients are skipped naturally: a stale
conn id is dropped when drained.
"""
function ws_send_all(server::AbstractServer, path::AbstractString, data::AbstractString)
    exec = server.executor
    exec isa AsyncExecutor || return nothing
    isopen(exec.replies) || return nothing
    ids = lock(server.runtime.ws_lock) do
        Int[id for (id, e) in server.runtime.ws_clients if e.uri == path]
    end
    frame = Message(String(data))
    for id in ids
        isopen(exec.replies) || break
        put!(exec.replies, Tagged{Union{Response,StreamResponse,Message}}(id, frame))
    end
    return nothing
end

# --- WS Dispatch ---

function invoke_ws(server::AbstractServer, request::Tagged{Intent})
    endpoint = getwsendpoint(server.router, request.payload.uri)
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
