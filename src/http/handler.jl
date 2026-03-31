"""
    HTTP handler — translates Mongoose C events into high-level Request/Response.
"""

# --- Static file serving (C-level, event-loop thread only) ---

"""
    _servestatic!(server, conn, ev_data) → Bool

If a static root directory is configured, check whether the request URI
matches a file in that directory and serve it via `mg_http_serve_dir`.
Returns `true` if the request was handled (caller must return immediately).

Must be called from the event-loop thread because `ev_data` is only valid
during the C callback and `mg_http_serve_dir` writes directly to `conn`.
"""
@inline function _servestatic!(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid}, method::Symbol, uri::String)::Bool
    server.core.static_dir === nothing && return false

    # Registered routes always take priority over static files.
    _matchroute(server.core.router, method, uri) !== nothing && return false

    # Only call the C library if an actual file exists on disk.
    # This prevents intercepting middleware-handled paths (e.g. /healthz, /metrics)
    # that have no corresponding file, which would cause mg_http_serve_dir to send
    # a 404 before the middleware pipeline ever runs.
    _static_file_exists(server.core.static_dir, uri) || return false

    dir = server.core.static_dir
    opts = Ref(MgHttpServeOpts(Base.unsafe_convert(Cstring, dir)))
    GC.@preserve dir begin
        mg_http_serve_dir(conn, ev_data, opts)
    end
    return true
end

"""
    _static_file_exists(root, uri) → Bool

Return `true` if `uri` maps to a real file (or pre-compressed `.gz` variant) under
`root`, or to a directory that has an `index.html`. Path-traversal safe.
"""
@inline function _static_file_exists(root::String, uri::String)::Bool
    rel = uri
    qi = findfirst('?', rel)
    qi !== nothing && (rel = rel[1:prevind(rel, qi)])

    rel = lstrip(rel, '/')

    candidate = normpath(joinpath(root, rel))

    # Guard against path traversal (e.g. /../../../etc/passwd).
    startswith(candidate, root) || return false

    isfile(candidate) && return true
    isfile(candidate * ".gz") && return true

    # Directory index fallback (empty path or trailing slash)
    index = joinpath(isempty(rel) ? root : candidate, "index.html")
    isfile(index) && return true

    return false
end

# --- SyncServer: direct dispatch on event-loop thread ---

function _onevent!(server::SyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    if _tryupgrade(server, conn, ev_data)
        return
    end

    message = MgHttpMessage(ev_data)

    if message.body.len > server.core.max_body_size
        _send!(conn, _errresponse(server, 413))
        return
    end

    # C-level static file serving (Range, ETag, gzip — fallback for unmatched routes)
    _servestatic!(server, conn, ev_data, _method(message), _uri(message)) && return

    req = Request(message)
    rid = _nextreqid!(server)
    res = try
        _servehttp(server, req)
    catch e
        @error "Handler error" exception=(e, catch_backtrace())
        _handleerror(server, req, e)
    end
    res = Response(res.status, res.headers * "X-Request-Id: $(rid)\r\n", res.body)
    _send!(conn, res)
    return
end

# --- AsyncServer: queue to worker channels ---

function _onevent!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    if _tryupgrade(server, conn, ev_data)
        return
    end

    message = MgHttpMessage(ev_data)

    # Body size limit check
    if message.body.len > server.core.max_body_size
        _send!(conn, _errresponse(server, 413))
        return
    end

    # C-level static file serving (Range, ETag, gzip — takes priority after routes)
    _servestatic!(server, conn, ev_data, _method(message), _uri(message)) && return

    id = Int(_nextreqid!(server))
    server.connections[id] = conn
    isopen(server.calls) && put!(server.calls, Tagged(id, Request(message)))
    return
end

# --- Dispatch pipeline (used by both sync handler and async workers) ---

"""
    _nextreqid!(server) → UInt64

Generate a monotonically increasing request ID.
"""
@inline _nextreqid!(server::AbstractServer) = Threads.atomic_add!(server.core.request_id, UInt64(1)) + UInt64(1)

"""
    _errresponse(server, status) → Response

Look up a custom response for `status` in `server.core.error_responses`.
Falls back to the module-level default.
"""
@inline function _errresponse(server::AbstractServer, status::Int)::Response
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
@inline function _handleerror(server::AbstractServer, ::Any, ::Any)::Response
    return _errresponse(server, 500)
end

"""
    _servehttp(server, request) → Response
"""
function _servehttp(server::AbstractServer, req::AbstractRequest)::Response
    final = (r, args...) -> _dispatchreq(server.core.router, r)
    if isempty(server.core.middlewares)
        return final(req)
    end
    return _pipeline(server.core.middlewares, req, Any[], final)
end

# Trim-safe specialization: StaticRouter dispatches directly, bypassing
# the middleware pipeline which uses abstract Function types and closures
# that cannot be resolved by --trim=safe.
@inline function _servehttp(server::SyncServer{<:StaticRouter}, req::AbstractRequest)::Response
    return static_dispatch(server.core.router, req)
end

@inline function _dispatchreq(router::Router, req)
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

@inline function _dispatchreq(router::StaticRouter, req)
    return static_dispatch(router, req)
end

# --- Response serialization ---

"""
    _send!(conn, response)

Send an HTTP response.  String bodies go through `mg_http_reply` which
handles Content-Length and clears Mongoose's `is_resp` flag.  Binary
(`Vector{UInt8}`) bodies are assembled into a raw buffer with `mg_send`
because `mg_http_reply` uses printf/strlen and truncates at 0x00.
`Connection: close` is added so the connection is not reused — `mg_send`
cannot clear `is_resp` and keep-alive would hang.
"""
function _send!(conn::MgConnection, res::Response)
    if res.body isa Vector{UInt8}
        head = "HTTP/1.1 $(res.status) OK\r\n$(res.headers)Content-Length: $(length(res.body))\r\nConnection: close\r\n\r\n"
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
    _servehttp_timeout(server, req, timeout_ms) → Response

Execute request handling with a timeout. If the handler exceeds `timeout_ms`,
returns 504 Gateway Timeout. Used only by AsyncServer workers.
"""
function _servehttp_timeout(server::AbstractServer, req::AbstractRequest, timeout_ms::Integer)::Response
    ch = Channel{Response}(1)
    t = Threads.@spawn begin
        try
            put!(ch, _servehttp(server, req))
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
                return _errresponse(server, 504)
            end
            yield()
        end
    finally
        close(timer)
    end
end
