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

# Generation id for reply routing: a stale worker reply cannot hit a reused pointer.
@inline function ws_id_of(server::AbstractServer, conn::MgConnection)::Int
    return lock(server.runtime.ws_lock) do
        get(server.runtime.ws_gen_ids, conn, 0)
    end
end

# --- Upgrade ---

function ws_upgrade!(server, conn, ev_data, uri, endpoint, msg)
    headers = parse_headers(msg)
    # Gate on Sec-WebSocket-Key: mongoose's own acceptance criterion (else 426).
    is_upgrade = haskey(headers, "sec-websocket-key")
    if !is_upgrade
        mg_ws_upgrade(conn, ev_data, C_NULL)
        return
    end

    if !isempty(endpoint.allowed_origins)
        origin = get(headers, "origin", "")
        if !any(o -> o == origin, endpoint.allowed_origins)
            mgjl_http_reply_bin(conn, 403, "", "Forbidden")
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
            mgjl_http_reply_bin(conn, 403, "", "Forbidden")
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
    # RFC 6455 §5.5: control frames must be unfragmented, ≤125 bytes, RSV=0;
    # a CLOSE payload is 0 or ≥2 bytes.
    if rsv || !fin || len > 125 || (op == WS_OP_CLOSE && len == 1)
        # RFC 6455 §5.5 violation: send a protocol-error Close frame and drain.
        mgjl_ws_close(conn, 1002, "WebSocket control-frame violation")
        return nothing
    end
    # Keep-alive bookkeeping only; mongoose already auto-replies PING/CLOSE.
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
        mgjl_ws_close(conn, 1002, "WebSocket RSV bit set")
        return
    end

    if msg.data.len > server.config.ws_max_frame_bytes
        mgjl_ws_close(conn, 1009, "WebSocket frame too large")
        return
    end

    ws_msg = parse_ws_message(msg)
    # RFC 6455 §5.6: text frames must carry valid UTF-8.
    if (msg.flags & 0x0F) == 0x01 && ws_msg.data isa String && !isvalid(ws_msg.data)
        mgjl_ws_close(conn, 1007, "WebSocket invalid UTF-8")
        return
    end
    uri = lock(server.runtime.ws_lock) do
        let e = get(server.runtime.ws_clients, conn_id, nothing); e === nothing ? "" : e.uri end
    end

    if server.executor isa AsyncExecutor
        exec = server.executor
        server.runtime.connections[conn_id] = conn
        tagged = Kernel.Tagged(conn_id, Kernel.Intent(ws_msg, uri))
        if !submit!(exec, () -> invoke_ws(server, tagged))
            @log_warn "WebSocket message dropped: worker queue full conn_id=$conn_id"
        end
    else
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
    uri === nothing || ws_close(server.router, uri)
    return nothing
end

# --- WS Idle Sweep ---

function ws_idle_sweep!(server::AbstractServer)
    now = time()
    # `last_active` is `time()` (seconds); the config is milliseconds.
    timeout = server.config.ws_idle_timeout_ms / 1000.0
    stale = lock(server.runtime.ws_lock) do
        ids = Int[]
        for (id, entry) in server.runtime.ws_clients
            if (now - entry.last_active) > timeout
                entry.closing = true
                push!(ids, id)
            end
        end
        return ids
    end
    for id in stale
        conn = get(server.runtime.connections, id, nothing)
        conn === nothing && continue
        # Send a proper Close frame (1001 "going away") and drain. The poll
        # loop then runs the real close path (epoll DEL + closesocket).
        mgjl_ws_close(conn, 1001, "WebSocket idle timeout")
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
        tagged = Kernel.Tagged{Kernel.ReplyPayload}(id, frame)
        # Non-blocking: a full reply queue drops the frame for that client
        # rather than stalling the caller (which may be a request handler).
        _offer_reply!(exec, tagged) ||
            Threads.atomic_add!(server.runtime.ws_dropped, UInt64(1))
    end
    return nothing
end

# --- WS Dispatch ---

# Router protocol: three hooks let the transport dispatch WS events without
# assuming how endpoints are stored. The generic implementations resolve the
# endpoint via `getwsendpoint` (the dynamic `Router`); `StaticRouter` methods
# scan its typed table and call the concrete handlers (trim-safe).
function ws_upgrade(router::AbstractRouter, server::AbstractServer, conn::MgConnection,
                    ev_data::Ptr{Cvoid}, uri::String, msg)
    endpoint = getwsendpoint(router, uri)
    endpoint === nothing && return false
    ws_upgrade!(server, conn, ev_data, uri, endpoint, msg)
    return true
end

function ws_message(router::AbstractRouter, request::Kernel.Tagged{Kernel.Intent})
    endpoint = getwsendpoint(router, request.payload.uri)
    endpoint === nothing && return nothing
    return call_ws_endpoint(endpoint, request)
end

function ws_close(router::AbstractRouter, uri::String)
    endpoint = getwsendpoint(router, uri)
    (endpoint === nothing || endpoint.on_close === nothing) && return nothing
    try
        endpoint.on_close()
    catch e
        @log_error "WebSocket on_close error uri=$uri" e catch_backtrace()
    end
    return nothing
end

# --- StaticRouter: typed WS dispatch (no Dict, no abstract handler call) ---

@inline function _scan_ws_upgrade(::Tuple{}, server, conn, ev_data, uri, msg)
    return false
end

@inline function _scan_ws_upgrade(routes::Tuple, server, conn, ev_data, uri, msg)
    route = routes[1]
    if route.path == uri
        ws_upgrade!(server, conn, ev_data, uri, route, msg)
        return true
    end
    return _scan_ws_upgrade(Base.tail(routes), server, conn, ev_data, uri, msg)
end

ws_upgrade(router::StaticRouter, server::AbstractServer, conn::MgConnection,
           ev_data::Ptr{Cvoid}, uri::String, msg) =
    _scan_ws_upgrade(router.ws_routes, server, conn, ev_data, uri, msg)

@inline function _invoke_ws_static(route::Kernel.StaticWSRoute{M,O,C},
                                   request::Kernel.Tagged{Kernel.Intent}) where {M,O,C}
    try
        res = route.on_message(request.payload.body)
        return tag_ws(request.id, res)
    catch e
        @log_error "WebSocket on_message error uri=$(request.payload.uri)" e catch_backtrace()
    end
    return nothing
end

@inline _scan_ws_msg(::Tuple{}, uri, request) = nothing
@inline function _scan_ws_msg(routes::Tuple, uri, request)
    route = routes[1]
    route.path == uri && return _invoke_ws_static(route, request)
    return _scan_ws_msg(Base.tail(routes), uri, request)
end

ws_message(router::StaticRouter, request::Kernel.Tagged{Kernel.Intent}) =
    _scan_ws_msg(router.ws_routes, request.payload.uri, request)

@inline _run_ws_close(::Nothing) = nothing
@inline function _run_ws_close(f::F) where {F}
    try
        f()
    catch e
        @log_error "WebSocket on_close error" e catch_backtrace()
    end
    return nothing
end

@inline _scan_ws_close(::Tuple{}, uri) = nothing
@inline function _scan_ws_close(routes::Tuple, uri)
    route = routes[1]
    route.path == uri && return _run_ws_close(route.on_close)
    return _scan_ws_close(Base.tail(routes), uri)
end

ws_close(router::StaticRouter, uri::String) = _scan_ws_close(router.ws_routes, uri)

# --- Transport entry points ---

function invoke_ws(server::AbstractServer, request::Kernel.Tagged{Kernel.Intent})
    return ws_message(server.router, request)
end

tag_ws(id, res::Message)        = Kernel.Tagged{Kernel.ReplyPayload}(id, res)
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
