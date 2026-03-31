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
    # Strip query string
    rel = uri
    qi = findfirst('?', rel)
    qi !== nothing && (rel = rel[1:prevind(rel, qi)])

    # Strip leading slashes to get a relative path
    rel = lstrip(rel, '/')

    # Candidate absolute path
    candidate = normpath(joinpath(root, rel))

    # Path traversal guard
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

    # Body size limit check
    if message.body.len > server.core.max_body_size
        _send!(conn, Response(413, ContentType.text, "413 Payload Too Large"))
        return
    end

    # C-level static file serving (Range, ETag, gzip — fallback for unmatched routes)
    _servestatic!(server, conn, ev_data, _method(message), _uri(message)) && return

    req = Request(message)
    res = try
        _servehttp(server, req)
    catch e
        @error "Handler error" exception=(e, catch_backtrace())
        Response(500, ContentType.text, "500 Internal Server Error")
    end
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
        _send!(conn, Response(413, ContentType.text, "413 Payload Too Large"))
        return
    end

    # C-level static file serving (Range, ETag, gzip — fallback for unmatched routes)
    _servestatic!(server, conn, ev_data, _method(message), _uri(message)) && return

    id = Int(conn)
    server.connections[id] = conn
    isopen(server.calls) && put!(server.calls, Tagged(id, Request(message)))
    return
end

# --- Dispatch pipeline (used by both sync handler and async workers) ---

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
"""
function _send!(conn::MgConnection, res::Response)
    mg_http_reply(conn, res.status, res.headers, res.body)
end
