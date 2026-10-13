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

# Monotonic per-server connection id (shared with HTTP async requests).
@inline _next_conn_id(server::AbstractServer)::Int =
    Int(Threads.atomic_add!(server.runtime.conn_seq, UInt64(1)) + UInt64(1))

@inline function ws_register!(server::AbstractServer, id::Int, conn::MgConnection,
                              wsc::Kernel.WSConn)
    lock(server.runtime.ws_lock) do
        server.runtime.ws_clients[id] = wsc
        server.runtime.ws_gen_ids[conn] = id
    end
    # Track the connection so idle sweeps can send close frames in sync mode
    # too (async mode also inserts it, but the mapping is mode-agnostic now).
    server.runtime.connections[id] = conn
    return id
end

# Per-event client handle built from the connection record; params are empty
# until typed parametric WS routes land (`matchws`).
@inline _ws_client(id::Int, wsc::Kernel.WSConn, params=NamedTuple()) =
    Kernel.WSClient(id, wsc.uri, params, wsc.request, wsc.state)

# Generation id for reply routing: a stale worker reply cannot hit a reused pointer.
@inline function ws_id_of(server::AbstractServer, conn::MgConnection)::Int
    return lock(server.runtime.ws_lock) do
        get(server.runtime.ws_gen_ids, conn, 0)
    end
end

# --- Upgrade ---

"""
    WSUpgraded — marker returned by the upgrade terminal when the handshake was
    consumed (upgraded, or answered by mongoose's native 426).

    Middleware see it as the `next()` result; anything that is not a `Response`
    means "the request is handled, there is nothing to send". This mirrors how
    a `StreamResponse` already travels through the pipeline.
"""
struct WSUpgraded end
const WS_UPGRADED = WSUpgraded()

"""
    ws_upgrade!(server, conn, ev_data, uri, endpoint, msg, req) → WSUpgraded | Response

Perform the handshake for a resolved endpoint. `req` is the pipeline request
(DI services attached), so `on_open` receives the same object the middleware
saw. Endpoint-level rejections (origin allowlist, `on_open` returning `false`)
come back as `403` Responses so they travel the normal send path; a successful
upgrade (or mongoose's 426 for a non-upgrade request) returns `WS_UPGRADED`.
"""
function ws_upgrade!(server, conn, ev_data, uri, endpoint, msg, req)::Union{WSUpgraded,Response}
    headers = parse_headers(msg)
    # Gate on Sec-WebSocket-Key: mongoose's own acceptance criterion (else 426).
    if !haskey(headers, "sec-websocket-key")
        mg_ws_upgrade(conn, ev_data, C_NULL)
        return WS_UPGRADED
    end

    if !isempty(endpoint.allowed_origins)
        origin = get(headers, "origin", "")
        if !any(o -> o == origin, endpoint.allowed_origins)
            return Response(403, Pair{String,String}[], "Forbidden")
        end
    end

    # Allocate the connection record before `on_open` so the callback gets a
    # live client (id + state + handshake request). A rejection discards it.
    id = _next_conn_id(server)
    wsc = Kernel.WSConn(uri, req)
    client = _ws_client(id, wsc)

    if endpoint.on_open !== nothing
        accepted = try
            endpoint.on_open(req, client) !== false
        catch e
            @log_error "WebSocket on_open error uri=$uri" e catch_backtrace()
            true
        end
        accepted || return Response(403, Pair{String,String}[], "Forbidden")
    end
    mg_ws_upgrade(conn, ev_data, C_NULL)
    ws_register!(server, id, conn, wsc)
    return WS_UPGRADED
end

"""
    ws_handle_upgrade(server, conn, ev_data, method, uri, msg, endpoint)

Run the WebSocket handshake through the middleware pipeline. Global (and
path-scoped) middleware observe the upgrade request; a short-circuiting
`Response` (401/403/429…) aborts the handshake and is sent normally. Otherwise
the terminal performs the upgrade and returns `WS_UPGRADED`.

Runs on the poll thread — the C upgrade is not thread-safe — so handshake
middleware should stay fast (no blocking I/O).
"""
function ws_handle_upgrade(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid},
                           method::Symbol, uri::String, msg, endpoint)
    # Single assignment before capture: a reassigned `req` would be boxed by
    # the closure below (Core.Box), which the trim verifier rejects.
    req = Kernel._attach_services(
        adapt_request(msg, method, uri; remote_addr=cached_remote_addr(server, conn)),
        server.context.registries.services)
    terminal = (r) -> ws_upgrade!(server, conn, ev_data, uri, endpoint, msg, r)
    res = Kernel._guarded_process(server.context, req) do
        isempty(server.context.middlewares) ? terminal(req) :
            runpipeline(server.context.middlewares, req, terminal)
    end
    if res isa StreamResponse
        # A short-circuiting middleware may stream its rejection (e.g. SSE).
        send_stream_response!(server, conn, res)
    elseif res isa Response
        res = _echo_conn_close!(res, req)
        send_http_response!(conn, res, resolve_request_id(req, server))
        _response_wants_close(res) && mgjl_conn_close_after_send(conn)
    end
    return nothing
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
    wsc = lock(server.runtime.ws_lock) do
        get(server.runtime.ws_clients, conn_id, nothing)
    end
    wsc === nothing && return

    if server.executor isa AsyncExecutor
        exec = server.executor
        server.runtime.connections[conn_id] = conn
        tagged = Kernel.Tagged(conn_id, Kernel.Intent(ws_msg, wsc.uri, wsc))
        if !submit!(exec, () -> invoke_ws(server, tagged))
            @log_warn "WebSocket message dropped: worker queue full conn_id=$conn_id"
        end
    else
        tagged = Kernel.Tagged(conn_id, Kernel.Intent(ws_msg, wsc.uri, wsc))
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
    entry === nothing && return nothing
    ws_close(server, server.router, conn_id, entry)
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

"""
    sendws(server, client::WSClient, data) → nothing

Send one frame to a single WebSocket client (`Message`, `String`, or
`Vector{UInt8}`; `nothing` is a no-op). With an async executor the frame is
routed through the reply queue like `broadcastws`, so it is safe to call from
any task; with a sync executor it is written directly and must be called from
the poll thread (i.e. inside a handler). A closed/stale client is skipped.
"""
function sendws(server::AbstractServer, client::Kernel.WSClient, data)
    tagged = tag_ws(client.id, data)
    tagged === nothing && return nothing
    exec = server.executor
    if exec isa AsyncExecutor
        _offer_reply!(exec, tagged) ||
            Threads.atomic_add!(server.runtime.ws_dropped, UInt64(1))
    else
        conn = get(server.runtime.connections, client.id, nothing)
        conn === nothing && return nothing
        send_ws_frame!(conn, tagged.payload)
    end
    return nothing
end

# --- WS Dispatch ---

# Router protocol: three hooks let the transport dispatch WS events without
# assuming how endpoints are stored. The generic implementations resolve the
# endpoint via `getwsendpoint` (the dynamic `Router`); `StaticRouter` methods
# scan its typed table and call the concrete handlers (trim-safe).
#
# `resolve_ws` is the side-effect-free lookup the upgrade pipeline needs before
# running middleware; the actual handshake lives in `ws_upgrade!`.
@inline resolve_ws(router::AbstractRouter, uri::String) = getwsendpoint(router, uri)

function ws_message(server::AbstractServer, router::AbstractRouter,
                    request::Kernel.Tagged{Kernel.Intent})
    endpoint = getwsendpoint(router, request.payload.uri)
    endpoint === nothing && return nothing
    client = _ws_client(request.id, request.payload.conn)
    return call_ws_endpoint(endpoint, request, client)
end

function ws_close(server::AbstractServer, router::AbstractRouter, conn_id::Int,
                  wsc::Kernel.WSConn)
    endpoint = getwsendpoint(router, wsc.uri)
    (endpoint === nothing || endpoint.on_close === nothing) && return nothing
    try
        endpoint.on_close(_ws_client(conn_id, wsc))
    catch e
        @log_error "WebSocket on_close error uri=$(wsc.uri)" e catch_backtrace()
    end
    return nothing
end

# --- StaticRouter: typed WS dispatch (no Dict, no abstract handler call) ---

@inline _find_ws_route(::Tuple{}, uri) = nothing
@inline function _find_ws_route(routes::Tuple, uri)
    route = routes[1]
    route.path == uri && return route
    return _find_ws_route(Base.tail(routes), uri)
end

@inline resolve_ws(router::StaticRouter, uri::String) = _find_ws_route(router.ws_routes, uri)

@inline function _invoke_ws_static(route::Kernel.StaticWSRoute{M,O,C},
                                   request::Kernel.Tagged{Kernel.Intent}) where {M,O,C}
    try
        client = _ws_client(request.id, request.payload.conn)
        res = route.on_message(request.payload.body, client)
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

ws_message(server::AbstractServer, router::StaticRouter, request::Kernel.Tagged{Kernel.Intent}) =
    _scan_ws_msg(router.ws_routes, request.payload.uri, request)

@inline _run_ws_close(::Nothing, client) = nothing
@inline function _run_ws_close(f::F, client) where {F}
    try
        f(client)
    catch e
        @log_error "WebSocket on_close error" e catch_backtrace()
    end
    return nothing
end

@inline _scan_ws_close(::Tuple{}, uri, client) = nothing
@inline function _scan_ws_close(routes::Tuple, uri, client)
    route = routes[1]
    route.path == uri && return _run_ws_close(route.on_close, client)
    return _scan_ws_close(Base.tail(routes), uri, client)
end

ws_close(server::AbstractServer, router::StaticRouter, conn_id::Int, wsc::Kernel.WSConn) =
    _scan_ws_close(router.ws_routes, wsc.uri, _ws_client(conn_id, wsc))

# --- Transport entry points ---

invoke_ws(server::AbstractServer, request::Kernel.Tagged{Kernel.Intent}) =
    ws_message(server, server.router, request)

tag_ws(id, res::Message)        = Kernel.Tagged{Kernel.ReplyPayload}(id, res)
tag_ws(id, res::String)         = tag_ws(id, Message(res))
tag_ws(id, res::Vector{UInt8})  = tag_ws(id, Message(res))
tag_ws(id, ::Nothing)           = nothing

function call_ws_endpoint(endpoint::WSEndpoint, request::Kernel.Tagged{Kernel.Intent},
                          client::Kernel.WSClient)
    try
        res = endpoint.on_message(request.payload.body, client)
        return tag_ws(request.id, res)
    catch e
        @log_error "WebSocket on_message error uri=$(request.payload.uri)" e catch_backtrace()
    end
    return nothing
end
