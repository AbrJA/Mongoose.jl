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

@inline function ws_register!(server::AbstractServer, uri::String, conn::MgConnection)
    id = Int(Threads.atomic_add!(server.runtime.conn_seq, UInt64(1)) + UInt64(1))
    lock(server.runtime.ws_lock) do
        server.runtime.ws_clients[id] = Kernel.WSConn(uri, time(), false)
        server.runtime.ws_gen_ids[conn] = id
    end
    # Track the connection so idle sweeps can send close frames in sync mode
    # too (async mode also inserts it, but the mapping is mode-agnostic now).
    server.runtime.connections[id] = conn
    return id
end

# Generation id for a live WS connection (0 when unknown). Reply routing uses
# this id instead of the raw pointer, so a stale worker reply can never be
# delivered to a new client that happens to reuse the same address.
@inline function ws_id_of(server::AbstractServer, conn::MgConnection)::Int
    return lock(server.runtime.ws_lock) do
        get(server.runtime.ws_gen_ids, conn, 0)
    end
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
    ws_register!(server, uri, conn)
end

# --- WS Control Frames (Ping/Pong/Close) ---

function on_ws_control(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    op = msg.flags & 0x0F
    fin = (msg.flags & 0x80) != 0
    rsv = (msg.flags & 0x70) != 0
    len = Int(msg.data.len)
    println(stderr, "WSCTL flags=", string(msg.flags, base=2, pad=8), " op=", op, " fin=", fin, " rsv=", rsv, " len=", len)
    # RFC 6455 §5.5: control frames must be unfragmented, ≤125 bytes, RSV=0;
    # a CLOSE payload is 0 or ≥2 bytes.
    if rsv || !fin || len > 125 || (op == WS_OP_CLOSE && len == 1)
        # RFC 6455 §5.5 violation: drop the connection (no public Mongoose API
        # to flush a Close frame and then close cleanly).
        mg_error(conn, "WebSocket control-frame violation")
        return nothing
    end
    # Keep-alive bookkeeping only. Mongoose's WS layer already auto-replies:
    # PING → PONG and CLOSE → CLOSE echo + drain (see `ws_process` in the C
    # library), so replying here would send every control frame twice.
    if op == WS_OP_PING || op == WS_OP_PONG
        id = ws_id_of(server, conn); id != 0 && ws_touch!(server, id)
    end
    return nothing
end

# --- WS Message ---

function on_ws_message(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = MgWsMessage(ev_data)
    conn_id = ws_id_of(server, conn)
    conn_id == 0 && return
    ws_touch!(server, conn_id)

    if (msg.flags & 0x70) != 0
        mg_error(conn, "WebSocket RSV bit set")
        return
    end

    if msg.data.len > server.config.ws_max_frame_bytes
        mg_error(conn, "WebSocket frame too large")
        return
    end

    ws_msg = parse_ws_message(msg)
    # RFC 6455 §5.6: text frames must carry valid UTF-8.
    if (msg.flags & 0x0F) == 0x01 && ws_msg.data isa String && !isvalid(ws_msg.data)
        mg_error(conn, "WebSocket invalid UTF-8")
        return
    end
    uri = lock(server.runtime.ws_lock) do
        let e = get(server.runtime.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end
    end

    if server.executor isa AsyncExecutor
        # Async: submit the dispatch as a job to the worker pool
        exec = server.executor
        server.runtime.connections[conn_id] = conn
        tagged = Kernel.Tagged(conn_id, Kernel.Intent(ws_msg, uri))
        if !submit!(exec, () -> invoke_ws(server, tagged))
            @log_warn "WebSocket message dropped: worker queue full conn_id=$conn_id"
        end
    else
        # Sync: handle inline
        tagged = Kernel.Tagged(conn_id, Kernel.Intent(ws_msg, uri))
        result = invoke_ws(server, tagged)
        if result !== nothing
            send_ws_frame!(conn, result.payload)
        end
    end
end

# --- Connection Close ---

function on_connection_close(server::AbstractServer, conn::MgConnection, ::Ptr{Cvoid})
    delete!(server.runtime.conn_times, conn)
    delete!(server.runtime.awaiting_body, conn)
    delete!(server.runtime.awaiting_headers, conn)
    delete!(server.runtime.conn_addr, conn)
    conn_id = lock(server.runtime.ws_lock) do
        id = get(server.runtime.ws_gen_ids, conn, 0)
        delete!(server.runtime.ws_gen_ids, conn)
        id
    end
    conn_id != 0 && close_ws!(server, conn_id)
    filter!(kv -> kv.second != conn, server.runtime.connections)
    # Abort any active stream on this connection: unblocks the producer.
    st = pop!(server.runtime.streams, Int(conn), nothing)
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
        # Drop the idle peer. `mg_error` marks it closing; the poll loop runs
        # the real close path (epoll DEL + closesocket). `mg_close_conn`
        # would leak the fd and corrupt epoll.
        mg_error(conn, "WebSocket idle timeout")
    end
end

"""
    broadcastws(server, path, data)

Server-initiated WebSocket push: enqueue a text frame for every open client of
`path` (async executors only — the frame is routed through the same reply
queue the worker pool uses, so it is sent on the poll/callback thread and is
safe to call from any task). Idle/closed clients are skipped naturally: a stale
conn id is dropped when drained.
"""
function broadcastws(server::AbstractServer, path::AbstractString, data::AbstractString)
    exec = server.executor
    exec isa AsyncExecutor || return nothing
    isopen(exec.replies) || return nothing
    ids = lock(server.runtime.ws_lock) do
        Int[id for (id, e) in server.runtime.ws_clients if e.uri == path]
    end
    frame = Message(String(data))
    for id in ids
        tagged = Kernel.Tagged{Union{Response,StreamResponse,Message}}(id, frame)
        # Non-blocking: a full reply queue drops the frame for that client
        # rather than stalling the caller (which may be a request handler).
        _offer_reply!(exec, tagged) ||
            Threads.atomic_add!(server.runtime.ws_dropped, UInt64(1))
    end
    return nothing
end

# --- WS Dispatch ---

function invoke_ws(server::AbstractServer, request::Kernel.Tagged{Kernel.Intent})
    endpoint = getwsendpoint(server.router, request.payload.uri)
    endpoint === nothing && return nothing
    return call_ws_endpoint(endpoint, request)
end

tag_ws(id, res::Message)        = Kernel.Tagged{Union{Response,StreamResponse,Message}}(id, res)
tag_ws(id, res::String)         = tag_ws(id, Message(res))
tag_ws(id, res::Vector{UInt8})  = tag_ws(id, Message(res))
tag_ws(id, ::Nothing)           = nothing

function call_ws_endpoint(endpoint::WSEndpoint, request::Kernel.Tagged{Kernel.Intent})
    try
        res = endpoint.on_message(request.payload.body)
        return tag_ws(request.id, res)
    catch e
        @log_error "WebSocket on_message error uri=$(request.payload.uri)" e catch_backtrace()
    end
    return nothing
end
