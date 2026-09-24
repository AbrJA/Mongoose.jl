"""
    HTTP event handler — the hot path from C event → Request → Response → send.

    The dispatch pipeline itself (`process`, `dispatch_to_handler`,
    `errorresponse`) lives in `Kernel`; this file binds it to the
    transport/server.
"""

# --- Connection sweeps (poll thread only) ---

"""
    conn_sweep!(server)

Close connections that connected but never delivered a complete request
(slowloris defense). Bounded by `header_timeout_ms`; no-op when disabled.
"""
function conn_sweep!(server::AbstractServer)
    now = time()
    _sweep!(server, server.runtime.awaiting_headers,
            server.config.header_timeout_ms, now, "header timeout")
    _sweep!(server, server.runtime.awaiting_body,
            server.config.body_timeout_ms, now, "body timeout")
    return nothing
end

# Close connections whose entry is older than `timeout_ms` (0 = disabled).
# `mg_error` only marks closing; the poll loop deregisters the fd and closes
# the socket. Calling `mg_close_conn` would leak the fd and leave a dangling
# epoll registration (event-loop wedge).
function _sweep!(server::AbstractServer, track::Dict{Ptr{Cvoid},Float64},
                 timeout_ms::Int, now::Float64, reason::String)
    timeout_ms <= 0 && return nothing
    timeout = timeout_ms / 1000.0
    stale = Ptr{Cvoid}[]
    for (c, t) in track
        (now - t) > timeout && push!(stale, c)
    end
    for c in stale
        delete!(track, c)
        mg_error(c, reason)
    end
    return nothing
end

"""
    on_read(server, conn, ev_data)

Raw socket reads. Used to bound request-header bytes: once a pending
connection's receive buffer exceeds `max_header_bytes` and the header block is
still incomplete, the connection is dropped before more memory is buffered.
Complete-but-oversized headers are answered with a 431 at `MG_EV_HTTP_HDRS`.
"""
function on_read(server::AbstractServer, conn::MgConnection, ::Ptr{Cvoid})
    maxh = server.config.max_header_bytes
    maxh > 0 || return nothing
    haskey(server.runtime.awaiting_headers, conn) || return nothing
    len = Int(unsafe_load(Ptr{Csize_t}(reinterpret(UInt, conn) + _MG_CONN_RECV_LEN_OFFSET)))
    len <= maxh && return nothing
    # If the terminator is already in the buffer, HDRS will answer 431.
    buf = unsafe_load(Ptr{Ptr{UInt8}}(reinterpret(UInt, conn) + _MG_CONN_RECV_OFFSET))
    _has_header_terminator(buf, 0, len) && return nothing
    mg_error(conn, "header too large")
    return nothing
end

# Scan [start, len) for CRLFCRLF. Only called for over-cap buffers.
@inline function _has_header_terminator(buf::Ptr{UInt8}, start::Int, len::Int)::Bool
    i = start
    @inbounds while i + 3 < len
        if unsafe_load(buf, i + 1) == UInt8('\r') && unsafe_load(buf, i + 2) == UInt8('\n') &&
           unsafe_load(buf, i + 3) == UInt8('\r') && unsafe_load(buf, i + 4) == UInt8('\n')
            return true
        end
        i += 1
    end
    return false
end

"""
    on_headers(server, conn, ev_data)

`MG_EV_HTTP_HDRS` fires once the request headers are complete, even if the
body is still arriving. Two jobs:

1. Slowloris bookkeeping: drop the connection from the header-timeout watch,
   so a slow upload longer than `header_timeout_ms` is not killed mid-body.
2. Reject a message carrying BOTH `Content-Length` and `Transfer-Encoding`
   (RFC 9112 §6.1): front-ends may frame it differently than this server, so
   it is a request-smuggling vector. There is no public Mongoose API to send a
   response and close cleanly, so the connection is dropped (`mg_error`).
"""
function on_headers(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    delete!(server.runtime.awaiting_headers, conn)
    # Mongoose fires HDRS on *every poll* while a body is still pending, so
    # this handler must be idempotent per connection: `awaiting_body` doubles
    # as the "headers already processed" marker (its timestamp is the body
    # start).
    haskey(server.runtime.awaiting_body, conn) && return nothing

    if mg_http_get_header_ptr(ev_data, "Content-Length") != C_NULL &&
       mg_http_get_header_ptr(ev_data, "Transfer-Encoding") != C_NULL
        mg_error(conn, "Content-Length with Transfer-Encoding")
        return nothing
    end

    server.runtime.awaiting_body[conn] = time()
    return nothing
end

# Add a header to a response without mutating it: `errorresponse` may return
# the shared `DEFAULT_*` objects (or a user-registered `Response`), so
# in-place appends would accumulate across requests.
@inline function _add_header_once(res::Response, key::String, value::String)::Response
    get(res.headers, key, nothing) === nothing || return res
    h = copy(res.headers)
    push!(h, key => value)
    return Response(res.status, h, res.body)
end

# --- Request ID resolution ---

@inline function resolve_request_id(server::AbstractServer,
                                    client_id::Union{Nothing,String})::String
    if client_id !== nothing
        safe = Kernel.sanitize_header_value(client_id)
        !isempty(safe) && return safe
    end
    return string(Threads.atomic_add!(server.runtime.id_seq, UInt64(1)) + UInt64(1))
end

@inline resolve_request_id(req::Request, server::AbstractServer)::String =
    resolve_request_id(server, get(req.headers, "x-request-id", nothing))

# --- Connection: close echo (RFC 7230 §6.3) ---

# Mongoose honors a client's `Connection: close` by closing the socket after
# the response, but it does NOT announce that in the response headers — a
# client-side pool that saw a keep-alive-looking reply then hands out the
# dead connection, and the next request on it hangs. Echo the header so
# clients tear the connection down themselves.

@inline function conn_close_requested(req::Request)::Bool
    value = get(req.headers, "connection", "")
    for token in split(value, ',')
        lowercase(strip(token)) == "close" && return true
    end
    return false
end

@inline function _echo_conn_close!(res, req::Request)
    if conn_close_requested(req) && res isa Response
        return _add_header_once(res, "Connection", "close")
    end
    return res
end

# --- Shared preprocessing ---

function preprocess_http(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})::Union{Nothing,Request}
    msg = MgHttpMessage(ev_data)
    # A complete request arrived: it no longer counts against the timeouts.
    delete!(server.runtime.awaiting_headers, conn)
    delete!(server.runtime.awaiting_body, conn)

    # One-time ABI sanity check (read-only): the peer-address offset is the
    # only pinned layout left. On a mismatch, degrade loudly instead of
    # serving wrong addresses.
    if !server.runtime.abi_checked
        flags = unsafe_load(Ptr{UInt32}(reinterpret(UInt, conn) + _MG_CONN_FLAGS_OFFSET))
        ip6 = unsafe_load(Ptr{UInt8}(reinterpret(UInt, conn) + _MG_CONN_REM_OFFSET + 19))
        if ((flags >> 2) & 0x1) == 0 || msg.head.len == 0 || ip6 > 1
            @log_error "Mongoose ABI mismatch: pinned struct offsets do not match " *
                       "this build ($(Sys.MACHINE)); remote_addr is disabled. " *
                       "Re-verify _MG_CONN_* offsets for this platform."
            server.runtime.abi_ok = false
        end
        server.runtime.abi_checked = true
    end

    # Header-size cap: complete-but-oversized headers get a clean 431 (the
    # incomplete case is dropped by the sweep before more is buffered).
    if server.config.max_header_bytes > 0 && Int(msg.head.len) > server.config.max_header_bytes
        rid = resolve_request_id(server, get(parse_headers(msg), "x-request-id", nothing))
        send_http_response!(conn, errorresponse(server.errors, 431), rid)
        return nothing
    end

    method = parse_method(msg.method)
    uri = to_string(msg.uri)

    # 1. WebSocket upgrade check
    if haswsroutes(server.router)
        endpoint = getwsendpoint(server.router, uri)
        if endpoint !== nothing
            ws_upgrade!(server, conn, ev_data, uri, endpoint, msg)
            return nothing
        end
    end

    # 2. Body size enforcement (mongoose buffers up to its 8 MiB ceiling)
    if msg.body.len > server.config.max_body_bytes
        rid = resolve_request_id(server, get(parse_headers(msg), "x-request-id", nothing))
        send_http_response!(conn, errorresponse(server.errors, 413), rid)
        return nothing
    end

    # 3. Static file serving (before handler dispatch)
    if serve_static!(server, conn, ev_data, method, uri)
        return nothing
    end

    # 4. Build Request from FFI data
    return adapt_request(msg, method, uri; remote_addr=cached_remote_addr(server, conn))
end

# --- Unified HTTP handler (sync and async branching on the executor) ---

function on_http_message(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    req = preprocess_http(server, conn, ev_data)
    req === nothing && return

    if !(server.executor isa AsyncExecutor)
        # Sync path: handle inline
        res = try
            invoke_http(server, req)
        catch e
            @log_error "Handler error uri=$(req.uri)" e catch_backtrace()
            errorresponse(server.errors, req, 500)
        end
        res = _echo_conn_close!(res, req)
        rid = resolve_request_id(req, server)
        if res isa StreamResponse
            send_stream_response!(server, conn, res)
        else
            send_http_response!(conn, res::Response, rid)
        end
    else
        # Async path: enqueue a job to the worker pool. A client-requested
        # `Connection: close` is honored by the client closing its side; the
        # server cannot flush-and-close asynchronously through mongoose's
        # public API (only synchronous replies set `is_draining`), so the
        # header is not echoed here and the connection stays reusable.
        exec = server.executor
        timeout = server.config.request_timeout_ms

        # Timed-out handlers cannot be killed; once the runaway budget is
        # exhausted, shed new timed requests rather than accumulate more.
        if timeout > 0 && _bg_full(server)
            res = _add_header_once(errorresponse(server.errors, 503), "Retry-After", "1")
            @log_warn "Request shed: runaway timed-out tasks reached $(server.config.max_bg_tasks)"
            send_http_response!(conn, res::Response, resolve_request_id(req, server))
            return nothing
        end

        id = Int(Threads.atomic_add!(server.runtime.conn_seq, UInt64(1)) + UInt64(1))
        server.runtime.connections[id] = conn

        job = if timeout > 0
            () -> _http_job_timed(server, id, req, timeout)
        else
            () -> _http_job(server, id, req)
        end
        if !submit!(exec, job)
            delete!(server.runtime.connections, id)
            res = _add_header_once(errorresponse(server.errors, 503), "Retry-After", "1")
            send_http_response!(conn, res::Response, resolve_request_id(req, server))
        end
    end
end

# --- Async job builders (worker-pool payloads) ---

"""
    _http_job(server, id, request) → Kernel.Tagged

Build the reply for a buffered/streamed HTTP request, adding `X-Request-Id`.
"""
function _http_job(server::AbstractServer, id::Int, req::Request)
    rid = resolve_request_id(req, server)
    try
        res = try
            invoke_http(server, req)
        catch e
            @log_error "Handler error uri=$(req.uri)" e catch_backtrace()
            errorresponse(server.errors, req, 500)
        end
        if res isa StreamResponse
            return Kernel.Tagged{Union{Response,StreamResponse,Message}}(id, res)
        end
        resp = mergeheaders(res, ["X-Request-Id" => rid])
        return Kernel.Tagged{Union{Response,StreamResponse,Message}}(id, resp)
    catch e
        # Anything outside the handler's own try (post-processing) still gets a
        # reply, so the connection entry is cleaned up and the client answered.
        @log_error "Request job error uri=$(req.uri)" e catch_backtrace()
        return Kernel.Tagged{Union{Response,StreamResponse,Message}}(id, errorresponse(server.errors, req, 500))
    end
end

"""
    _http_job_timed(server, id, request, timeout) → Kernel.Tagged

Run `_http_job` under a `request_timeout_ms` deadline; on timeout reply 504 and
let the still-running task finish in the background. The task is tracked in
`server.runtime.bg_tasks` so it is not silently dropped (it may still hold
server/request references); its late reply is discarded because the
connection id is gone from `app.connections`.
"""
function _http_job_timed(server::AbstractServer, id::Int, req::Request, timeout::Integer)
    t = Threads.@spawn _http_job(server, id, req)
    r = timedwait(() -> istaskdone(t), timeout / 1000.0; pollint=0.002)
    if r === :ok
        return try
            fetch(t)
        catch e
            # A job that failed outside the handler's own try still gets a reply
            # so the connection entry is cleaned up and the client is answered.
            @log_error "Request job failed uri=$(req.uri)" e catch_backtrace()
            Kernel.Tagged{Union{Response,StreamResponse,Message}}(id, errorresponse(server.errors, req, 500))
        end
    end
    bg_track!(server, t)
    @log_warn "Request timeout uri=$(req.uri)"
    return Kernel.Tagged{Union{Response,StreamResponse,Message}}(id, errorresponse(server.errors, 504))
end

# --- HTTP dispatch (thin transport wrapper over the core pipeline) ---

function invoke_http(server::AbstractServer, req::Request)::Union{Response,StreamResponse}
    res = process(server.context, req)
    # HEAD responses must not carry a body (RFC 9110 §3.1). An explicit HEAD
    # endpoint may return a body from its handler, which would be sent as-is —
    # strip it here and let mongoose frame the empty body natively
    # (Content-Length: 0).
    if req.method === :head && res isa Response
        return Kernel._apply_head_semantics(res)
    end
    return res
end

# --- Static File Serving ---

@inline function serve_static!(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid},
                               method::Symbol, uri::String)::Bool
    isempty(server.mounts) && return false
    hasroute(server.router, uri) && return false

    for (dir, prefix) in server.mounts
        static_file_exists(dir, prefix, uri) || continue
        root_dir = prefix == "/" ? dir : "$dir,$prefix=$dir"
        opts = Ref(MgHttpServeOpts(Base.unsafe_convert(Cstring, root_dir)))
        GC.@preserve root_dir begin
            mg_http_serve_dir(conn, ev_data, opts)
        end
        return true
    end
    return false
end

@inline function static_file_exists(root::String, prefix::String, uri::String)::Bool
    if prefix == "/"
        rel = uri
    elseif startswith(uri, prefix * "/") || uri == prefix
        rel = uri[length(prefix)+1:end]
    else
        return false
    end

    qi = findfirst('?', rel)
    qi !== nothing && (rel = rel[1:prevind(rel, qi)])
    rel = lstrip(rel, '/')

    # Decode percent-escapes so the root guard and the dotfile rule see the
    # same path Mongoose will open. `+` stays literal in paths (RFC 3986).
    rel = urldecode(codeunits(rel), 1, ncodeunits(rel); plus=false)

    candidate = normpath(joinpath(root, rel))
    (candidate == root || startswith(candidate, root * Base.Filesystem.path_separator)) || return false
    _has_hidden_segment(rel) && return false

    isfile(candidate) && return true
    isfile(candidate * ".gz") && return true
    isfile(joinpath(isempty(rel) ? root : candidate, "index.html")) && return true
    return false
end

# Dotfiles are not served (`.env`, `.git`, editor backups); `.well-known` is
# the standardized exception (ACME challenges, security.txt). Every other
# dot-segment rejects the path, including `..`-normalized attempts.
function _has_hidden_segment(rel::String)::Bool
    isempty(rel) && return false
    first_seg = true
    for seg in eachsplit(rel, '/')
        isempty(seg) && continue
        if startswith(seg, '.')
            first_seg && seg == ".well-known" && (first_seg = false; continue)
            return true
        end
        first_seg = false
    end
    return false
end

# --- Routing convenience on server/app ---

function route!(server::AbstractServer, method::Symbol, path::AbstractString, handler::Function;
                middleware=nothing,
                metadata=nothing)
    _ensure_registratable(server, "routes")
    route!(server.router, method, path, handler; middleware=asmiddlewares(middleware), metadata=metadata)
    return server
end

function route!(server::AbstractServer, method::AbstractString, path::AbstractString, handler::Function;
                middleware=nothing,
                metadata=nothing)
    route!(server.router, Symbol(lowercase(method)), path, handler;
           middleware=asmiddlewares(middleware), metadata=metadata)
    return server
end

function ws!(server::AbstractServer, path::AbstractString; kwargs...)
    _ensure_registratable(server, "websocket routes")
    ws!(server.router, path; kwargs...)
    return server
end

function ws!(server::AbstractServer, path::AbstractString, handler::Function; kwargs...)
    _ensure_registratable(server, "websocket routes")
    ws!(server.router, path; on_message=handler, kwargs...)
    return server
end

# Method-specific helpers for server/app (extend Base where applicable to avoid ambiguity)
Base.get!(server::AbstractServer, path::AbstractString, h::Function) = (route!(server, :get, path, h); server)
post!(server::AbstractServer, path::AbstractString, h::Function) = (route!(server, :post, path, h); server)
Base.put!(server::AbstractServer, path::AbstractString, h::Function) = (route!(server, :put, path, h); server)
patch!(server::AbstractServer, path::AbstractString, h::Function) = (route!(server, :patch, path, h); server)
Base.delete!(server::AbstractServer, path::AbstractString, h::Function) = (route!(server, :delete, path, h); server)
options!(server::AbstractServer, path::AbstractString, h::Function) = (route!(server, :options, path, h); server)
head!(server::AbstractServer, path::AbstractString, h::Function) = (route!(server, :head, path, h); server)

# Do-block convenience
Base.get!(f::Function, server::AbstractServer, path::AbstractString) = Base.get!(server, path, f)
post!(f::Function, server::AbstractServer, path::AbstractString) = post!(server, path, f)
Base.put!(f::Function, server::AbstractServer, path::AbstractString) = Base.put!(server, path, f)
patch!(f::Function, server::AbstractServer, path::AbstractString) = patch!(server, path, f)
Base.delete!(f::Function, server::AbstractServer, path::AbstractString) = Base.delete!(server, path, f)
options!(f::Function, server::AbstractServer, path::AbstractString) = options!(server, path, f)
head!(f::Function, server::AbstractServer, path::AbstractString) = head!(server, path, f)

"""
    serve!(server, directory; uri_prefix="/")

Serve static files from `directory` under `uri_prefix` on the URL. The
directory is the positional argument; the URL prefix is always the keyword
(so the two can never be silently swapped).

Dotfiles (`.env`, `.git`, …) are not served; `.well-known` is allowed for
ACME challenges and `security.txt`. Symlinks inside the directory are
followed by the OS, so do not place links that escape the root.
"""
function serve!(server::AbstractServer, directory::AbstractString; uri_prefix::AbstractString="/")
    _ensure_registratable(server, "static mounts")
    dir = rstrip(abspath(directory), '/')
    isdir(dir) || throw(ArgumentError("serve!: directory does not exist: $dir"))
    prefix = "/" * lstrip(rstrip(uri_prefix, '/'), '/')
    push!(server.mounts, (dir, prefix))
    return server
end
