"""
    HTTP handler — translates Mongoose C events into high-level Request/Response.
"""

# --- HTTP status text lookup ---

"""
    _statustext(code) → String

Return the standard HTTP reason phrase for a status code.
"""
@inline function _statustext(code::Int)
    code == 200 && return "OK"
    code == 201 && return "Created"
    code == 204 && return "No Content"
    code == 301 && return "Moved Permanently"
    code == 302 && return "Found"
    code == 304 && return "Not Modified"
    code == 400 && return "Bad Request"
    code == 401 && return "Unauthorized"
    code == 403 && return "Forbidden"
    code == 404 && return "Not Found"
    code == 405 && return "Method Not Allowed"
    code == 413 && return "Payload Too Large"
    code == 429 && return "Too Many Requests"
    code == 500 && return "Internal Server Error"
    code == 502 && return "Bad Gateway"
    code == 503 && return "Service Unavailable"
    code == 504 && return "Gateway Timeout"
    return "OK"
end

# --- Static file serving (C-level, event-loop thread only) ---

"""
    _servestatic!(server, conn, ev_data) → Bool

If a static root directory is configured, check whether the request URI
matches a file in that directory and serve it via `mg_http_serve_dir`.
Returns `true` if the request was handled (caller must return immediately).

Must be called from the event-loop thread because `ev_data` is only valid
during the C callback and `mg_http_serve_dir` writes directly to `conn`.
"""
@inline function _servestatic!(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid}, method::Symbol, uri::String)
    isempty(server.core.static_dirs) && return false

    # Registered routes always take priority over static files.
    # Only do the (expensive) route match when static dirs exist.
    _matchroute(server.core.router, method, uri) !== nothing && return false

    # Try each registered static directory in order. The first one whose prefix
    # matches the URI and has a matching file on disk wins.
    for (dir, prefix) in server.core.static_dirs
        _static_file_exists(dir, prefix, uri) || continue

        # Build the root_dir string Mongoose expects. When there is a non-root
        # prefix, use the comma-separated "default,/prefix=dir" format so that
        # Mongoose strips the prefix before resolving the file path.
        root_dir = prefix == "/" ? dir : "$dir,$prefix=$dir"
        opts = Ref(MgHttpServeOpts(Base.unsafe_convert(Cstring, root_dir)))
        GC.@preserve root_dir begin
            mg_http_serve_dir(conn, ev_data, opts)
        end
        return true
    end

    return false
end

"""
    _static_file_exists(root, uri) → Bool

Return `true` if `uri` maps to a real file (or pre-compressed `.gz` variant) under
`root`, or to a directory that has an `index.html`. Path-traversal safe.
"""
@inline function _static_file_exists(root::String, prefix::String, uri::String)
    # Check that the URI starts with the configured prefix and strip it.
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

    candidate = normpath(joinpath(root, rel))

    # Guard against path traversal (e.g. /../../../etc/passwd).
    # A plain startswith is not sufficient — "/var/www/public2" starts with "/var/www/public".
    # Require the candidate to equal root exactly or begin with root + the platform separator.
    (candidate == root || startswith(candidate, root * Base.Filesystem.path_separator)) || return false

    isfile(candidate) && return true
    isfile(candidate * ".gz") && return true

    # Directory index fallback (empty path or trailing slash)
    index = joinpath(isempty(rel) ? root : candidate, "index.html")
    isfile(index) && return true

    return false
end

# --- SyncServer: direct dispatch on event-loop thread ---

function _onevent!(server::SyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    message = MgHttpMessage(ev_data)
    method = _method(message)
    uri    = _uri(message)

    # WebSocket upgrade check (skip entirely when no WS routes are registered)
    if _has_ws_routes(server.core.router)
        endpoint = _wsep(server.core.router, uri)
        if endpoint !== nothing
            _wsupgrade!(server, conn, ev_data, uri, endpoint, message)
            return
        end
    end

    if message.body.len > server.core.max_body_size
        _sendhttp!(conn, _errresponse(server, 413))
        return
    end

    # C-level static file serving (Range, ETag, gzip — fallback for unmatched routes)
    _servestatic!(server, conn, ev_data, method, uri) && return

    req = Request(message, method, uri)
    res = try
        _invokehttp(server, req)
    catch e
        @error "Handler error" exception=(e, catch_backtrace())
        _handleerror(server, req, e)
    end
    rid = _requestid_fast(message, server)
    _sendwithid!(conn, res, rid)
    return
end

# --- AsyncServer: queue to worker channels ---

function _onevent!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    message = MgHttpMessage(ev_data)
    method = _method(message)
    uri    = _uri(message)

    # WebSocket upgrade check (skip entirely when no WS routes are registered)
    if _has_ws_routes(server.core.router)
        endpoint = _wsep(server.core.router, uri)
        if endpoint !== nothing
            _wsupgrade!(server, conn, ev_data, uri, endpoint, message)
            return
        end
    end

    # Body size limit check
    if message.body.len > server.core.max_body_size
        _sendhttp!(conn, _errresponse(server, 413))
        return
    end

    # C-level static file serving (Range, ETag, gzip — takes priority after routes)
    _servestatic!(server, conn, ev_data, method, uri) && return

    id = Int(_nextreqid!(server))
    server.connections[id] = conn
    isopen(server.calls) && put!(server.calls, Tagged(id, Request(message, method, uri)))
    return
end

# --- Dispatch pipeline (used by both sync handler and async workers) ---

"""
    _nextreqid!(server) → UInt64

Generate a monotonically increasing request ID.
"""
@inline _nextreqid!(server::AbstractServer) = Threads.atomic_add!(server.core.request_id, UInt64(1)) + UInt64(1)

"""
    _sanitize_request_id(s) → String

Validate an incoming X-Request-Id value. Returns the original string if safe,
or an empty string if it contains HTTP header-injection characters (`\r`, `\n`)
or exceeds 128 bytes. This prevents response-splitting attacks when echoing
an untrusted client-supplied ID into a response header.
"""
@inline function _sanitize_request_id(s::String)::String
    length(s) > 128 && return ""
    @inbounds for i in 1:ncodeunits(s)
        b = codeunit(s, i)
        (b == 0x0d || b == 0x0a || b < 0x20) && return ""
    end
    return s
end

"""
    _requestid(req, server) → String

Return the request ID to embed in the `X-Request-Id` response header.
If the incoming request carries a valid `X-Request-Id` header it is forwarded
verbatim (enabling end-to-end distributed-trace correlation). Otherwise a new
monotonic ID is generated from the server's atomic counter.
"""
@inline function _requestid(req::AbstractRequest, server::AbstractServer)::String
    h = get(req.headers, "x-request-id", nothing)
    if h !== nothing
        safe = _sanitize_request_id(h)
        !isempty(safe) && return safe
    end
    return _uint64tostr(Threads.atomic_add!(server.core.request_id, UInt64(1)) + UInt64(1))
end

"""
    _requestid_fast(message, server) → String

Fast-path request ID extraction that reads directly from the raw C `MgHttpMessage`
headers, avoiding the cost of scanning the already-parsed `Vector{Pair}`.
"""
@inline function _requestid_fast(message::MgHttpMessage, server::AbstractServer)::String
    # Scan raw C headers for "x-request-id" (12 chars, case-insensitive)
    for h in message.headers
        h.name.buf == C_NULL && break
        h.name.len == 0 && break
        h.name.len == 12 || continue
        if _is_xrequestid(h.name.buf)
            val = _tostring(h.val)
            safe = _sanitize_request_id(val)
            !isempty(safe) && return safe
        end
    end
    return _uint64tostr(Threads.atomic_add!(server.core.request_id, UInt64(1)) + UInt64(1))
end

# Case-insensitive check for "x-request-id" (12 bytes) directly on C memory
@inline function _is_xrequestid(ptr::Ptr{UInt8})::Bool
    # Expected: x-request-id (any case)
    _tolower(unsafe_load(ptr, 1))  == UInt8('x') || return false
    unsafe_load(ptr, 2)            == UInt8('-') || return false
    _tolower(unsafe_load(ptr, 3))  == UInt8('r') || return false
    _tolower(unsafe_load(ptr, 4))  == UInt8('e') || return false
    _tolower(unsafe_load(ptr, 5))  == UInt8('q') || return false
    _tolower(unsafe_load(ptr, 6))  == UInt8('u') || return false
    _tolower(unsafe_load(ptr, 7))  == UInt8('e') || return false
    _tolower(unsafe_load(ptr, 8))  == UInt8('s') || return false
    _tolower(unsafe_load(ptr, 9))  == UInt8('t') || return false
    unsafe_load(ptr, 10)           == UInt8('-') || return false
    _tolower(unsafe_load(ptr, 11)) == UInt8('i') || return false
    _tolower(unsafe_load(ptr, 12)) == UInt8('d') || return false
    return true
end

@inline _tolower(b::UInt8) = (UInt8('A') <= b <= UInt8('Z')) ? (b | 0x20) : b

# Fast UInt64→String without going through `string()` (avoids Julia runtime formatting)
@inline function _uint64tostr(n::UInt64)::String
    n == 0 && return "0"
    buf = Vector{UInt8}(undef, 20)  # max UInt64 digits
    i = 20
    @inbounds while n > 0
        buf[i] = UInt8('0') + UInt8(n % 10)
        n = div(n, 10)
        i -= 1
    end
    return String(view(buf, i+1:20))
end

"""
    _appendreqid(headers, rid) → String

Append X-Request-Id header to response headers string.
"""
@inline function _appendreqid(headers::String, rid::AbstractString)
    return string(headers, "X-Request-Id: ", rid, "\r\n")
end

"""
    _errresponse(server, status) → Response

Look up a custom response for `status` in `server.core.error_responses`.
Falls back to the module-level default.
"""
@inline function _errresponse(server::AbstractServer, status::Int)
    r = get(server.core.error_responses, status, nothing)
    r !== nothing && return r
    status == 500 && return _DEFAULT_500
    status == 413 && return _DEFAULT_413
    status == 504 && return _DEFAULT_504
    return Response(status, ContentType.text, "$status Error")
end

"""
    _handleerror(server, req, e) → Response

Return the custom 500 response from `error_responses` if configured,
otherwise return the default 500. No dynamic function call — trim-safe.
"""
@inline function _handleerror(server::AbstractServer, ::Any, ::Any)
    return _errresponse(server, 500)
end

"""
    _invokehttp(server, request) → Response
"""
function _invokehttp(server::AbstractServer, req::AbstractRequest)
    if isempty(server.core.middlewares)
        return _dispatchhttp(server.core.router, req)
    end
    final = (r, args...) -> _dispatchhttp(server.core.router, r)
    return _pipeline(server.core.middlewares, req, Any[], final)
end

# Trim-safe specialization: StaticRouter dispatches directly, bypassing
# the middleware pipeline which uses abstract Function types and closures
# that cannot be resolved by --trim=safe.
@inline function _invokehttp(server::SyncServer{<:StaticRouter}, req::AbstractRequest)
    return static_dispatch(server.core.router, req)
end

@inline function _dispatchhttp(router::Router, req)
    matched = _matchroute(router, req.method, req.uri)
    if matched !== nothing
        handler = _gethandler(matched.handlers, req.method)
        if handler !== nothing
            return handler(req, matched.params...)
        end
        # Auto HEAD: use GET handler, return headers only
        if req.method === :head
            get_h = matched.handlers.get
            if get_h !== nothing
                resp = get_h(req, matched.params...)
                return Response(resp.status, resp.headers, "")
            end
        end
        return Response(405, ContentType.text, "405 Method Not Allowed")
    end
    return Response(404, ContentType.text, "404 Not Found")
end

@inline function _dispatchhttp(router::StaticRouter, req)
    return static_dispatch(router, req)
end

# --- Response serialization ---

"""
    _sendhttp!(conn, response)

Send an HTTP response.  String bodies go through `mg_http_reply` which
handles Content-Length and clears Mongoose's `is_resp` flag.  Binary
(`Vector{UInt8}`) bodies are assembled into a raw buffer with `mg_send`
because `mg_http_reply` uses printf/strlen and truncates at 0x00.
`Connection: close` is added so the connection is not reused — `mg_send`
cannot clear `is_resp` and keep-alive would hang.
"""
function _sendhttp!(conn::MgConnection, res::Response)
    if res.body isa Vector{UInt8}
        head = "HTTP/1.1 $(res.status) $(_statustext(res.status))\r\n$(res.headers)Content-Length: $(length(res.body))\r\nConnection: close\r\n\r\n"
        hlen = ncodeunits(head)
        buf  = Vector{UInt8}(undef, hlen + length(res.body))
        copyto!(buf, 1, codeunits(head), 1, hlen)
        isempty(res.body) || copyto!(buf, hlen + 1, res.body, 1, length(res.body))
        mg_send(conn, buf)
    else
        mg_http_reply(conn, res.status, res.headers, res.body)
    end
end

"""
    _sendwithid!(conn, response, rid)

Send an HTTP response with X-Request-Id header injected directly.
Avoids allocating a new Response struct and header string concatenation.
"""
function _sendwithid!(conn::MgConnection, res::Response, rid::String)
    headers = string(res.headers, "X-Request-Id: ", rid, "\r\n")
    if res.body isa Vector{UInt8}
        head = "HTTP/1.1 $(res.status) $(_statustext(res.status))\r\n$(headers)Content-Length: $(length(res.body))\r\nConnection: close\r\n\r\n"
        hlen = ncodeunits(head)
        buf  = Vector{UInt8}(undef, hlen + length(res.body))
        copyto!(buf, 1, codeunits(head), 1, hlen)
        isempty(res.body) || copyto!(buf, hlen + 1, res.body, 1, length(res.body))
        mg_send(conn, buf)
    else
        mg_http_reply(conn, res.status, headers, res.body)
    end
end

"""
    _invokehttp_timeout(server, req, timeout_ms) → Response

Execute request handling with a timeout. If the handler exceeds `timeout_ms`,
returns 504 Gateway Timeout. Used only by AsyncServer workers.
"""
function _invokehttp_timeout(server::AbstractServer, req::AbstractRequest, timeout_ms::Integer)
    ch = Channel{Response}(1)
    t = Threads.@spawn begin
        try
            put!(ch, _invokehttp(server, req))
        catch e
            put!(ch, _handleerror(server, req, e))
        end
    end
    timer = Timer(timeout_ms / 1000.0)
    try
        while true
            if isready(ch)
                return take!(ch)
            end
            if !isopen(timer)
                @warn "Request timed out" uri=req.uri timeout_ms=timeout_ms
                # Schedule interrupt so the handler task doesn't leak
                Base.schedule(t, InterruptException(); error=true)
                return _errresponse(server, 504)
            end
            yield()
        end
    finally
        close(timer)
    end
end
