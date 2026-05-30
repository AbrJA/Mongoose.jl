"""
    HTTP event handler — the hot path from C event → Request → Response → send.

    Key design: shared `preprocess_http` eliminates duplication between Server/Async.
"""

# --- Default error responses (module-level singletons) ---

const DEFAULT_500 = Response(Plain, "500 Internal Server Error"; status=500)
const DEFAULT_413 = Response(Plain, "413 Payload Too Large"; status=413)
const DEFAULT_503 = Response(Plain, "503 Service Unavailable"; status=503)
const DEFAULT_504 = Response(Plain, "504 Gateway Timeout"; status=504)

"""
    error_response(server, status) → Response

Look up custom error response, falling back to module defaults.
"""
@inline function error_response(server::AbstractServer, status::Int)::Response
    custom = get(server.core.errors, status, nothing)
    custom !== nothing && return custom
    status == 500 && return DEFAULT_500
    status == 413 && return DEFAULT_413
    status == 503 && return DEFAULT_503
    status == 504 && return DEFAULT_504
    return Response(Plain, "$status $(status_reason(status))"; status=status)
end

# --- Request ID resolution ---

"""
    resolve_request_id(req, server) → String

Forward incoming X-Request-Id if valid, otherwise generate monotonic ID.
"""
@inline function resolve_request_id(req::Request, server::AbstractServer)::String
    h = get(req.headers, "x-request-id", nothing)
    if h !== nothing
        safe = sanitize_header_value(h)
        !isempty(safe) && return safe
    end
    return uint_to_string(Threads.atomic_add!(server.core.id_seq, UInt64(1)) + UInt64(1))
end

"""
    resolve_request_id_fast(msg, server) → String

Fast-path: scan raw C headers for X-Request-Id without parsing all headers.
"""
@inline function resolve_request_id_fast(msg::MgHttpMessage, server::AbstractServer)::String
    for h in msg.headers
        h.name.buf == C_NULL && break
        h.name.len == 0 && break
        h.name.len == 12 || continue
        if _is_x_request_id(h.name.buf)
            val = to_string(h.val)
            safe = sanitize_header_value(val)
            !isempty(safe) && return safe
        end
    end
    return uint_to_string(Threads.atomic_add!(server.core.id_seq, UInt64(1)) + UInt64(1))
end

@inline function _is_x_request_id(ptr::Ptr{UInt8})::Bool
    to_lower(unsafe_load(ptr, 1))  == UInt8('x') || return false
    unsafe_load(ptr, 2)            == UInt8('-') || return false
    to_lower(unsafe_load(ptr, 3))  == UInt8('r') || return false
    to_lower(unsafe_load(ptr, 4))  == UInt8('e') || return false
    to_lower(unsafe_load(ptr, 5))  == UInt8('q') || return false
    to_lower(unsafe_load(ptr, 6))  == UInt8('u') || return false
    to_lower(unsafe_load(ptr, 7))  == UInt8('e') || return false
    to_lower(unsafe_load(ptr, 8))  == UInt8('s') || return false
    to_lower(unsafe_load(ptr, 9))  == UInt8('t') || return false
    unsafe_load(ptr, 10)           == UInt8('-') || return false
    to_lower(unsafe_load(ptr, 11)) == UInt8('i') || return false
    to_lower(unsafe_load(ptr, 12)) == UInt8('d') || return false
    return true
end

# --- Shared preprocessing (eliminates Server/Async duplication) ---

"""
    preprocess_http(server, conn, ev_data) → Union{Nothing, Request}

Shared preprocessing for HTTP messages. Returns:
- `nothing` if the request was already handled (WS upgrade, static serve, rejection)
- `Request` if it needs to be dispatched to a handler
"""
function preprocess_http(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})::Union{Nothing,Request}
    msg = MgHttpMessage(ev_data)
    method = parse_method(msg.method)
    uri = to_string(msg.uri)

    # 1. WebSocket upgrade check
    if has_ws_routes(server.core.router)
        endpoint = ws_endpoint(server.core.router, uri)
        if endpoint !== nothing
            ws_upgrade!(server, conn, ev_data, uri, endpoint, msg)
            return nothing
        end
    end

    # 2. Body size enforcement
    if msg.body.len > server.core.max_body
        send_http_response!(conn, error_response(server, 413))
        return nothing
    end

    # 3. Static file serving (before handler dispatch)
    if serve_static!(server, conn, ev_data, method, uri)
        return nothing
    end

    # 4. Build Request from FFI data
    return adapt_request(msg, method, uri)
end

# --- Server (sync) HTTP handler ---

function on_http_message(server::Server, conn::MgConnection, ev_data::Ptr{Cvoid})
    req = preprocess_http(server, conn, ev_data)
    req === nothing && return

    res = try
        invoke_http(server, req)
    catch e
        @log_error "Handler error uri=$(req.uri)" e catch_backtrace()
        error_response(server, 500)
    end
    rid = resolve_request_id(req, server)
    if res isa StreamResponse
        send_stream_response!(conn, res)
    else
        send_http_response!(conn, res::Response, rid)
    end
end

# --- Async HTTP handler ---

function on_http_message(server::Async, conn::MgConnection, ev_data::Ptr{Cvoid})
    req = preprocess_http(server, conn, ev_data)
    req === nothing && return

    # Enqueue to worker pool
    id = Int(Threads.atomic_add!(server.core.id_seq, UInt64(1)) + UInt64(1))
    server.connections[id] = conn

    tagged = Tagged{Union{Request,Intent}}(id, req)
    if !try_enqueue!(server.calls, tagged, server.nqueue)
        delete!(server.connections, id)
        send_http_response!(conn, error_response(server, 503))
    end
end

# --- HTTP dispatch pipeline ---

"""
    invoke_http(server, request) → Union{Response, StreamResponse}

Execute the middleware pipeline and route dispatch.
Service injection is handled here (single point of responsibility).
"""
function invoke_http(server::AbstractServer, req::Request)::Union{Response,StreamResponse}
    # Attach services to request context if configured
    if server.core.services !== nothing
        ctx = context!(req)
        ctx[:_services] = server.core.services
    end

    if isempty(server.core.middlewares)
        return dispatch_to_handler(server.core.router, req)
    end
    final = (r) -> dispatch_to_handler(server.core.router, r)
    return execute_pipeline(server.core.middlewares, req, final)
end

# Trim-safe specialization: StaticRouter bypasses middleware
@inline function invoke_http(server::Server{<:StaticRouter}, req::Request)::Union{Response,StreamResponse}
    return dispatch_static(server.core.router, req)
end

"""
    dispatch_to_handler(router, request) → Union{Response, StreamResponse}

Route a request to its handler. Handles 404, 405, and auto-HEAD.
"""
function dispatch_to_handler(router::Router, req::Request)::Union{Response,StreamResponse}
    matched = dispatch_route(router, req.method, req.uri)
    if matched !== nothing
        handler = get_handler(matched.handlers, req.method)
        if handler !== nothing
            result = handler(req, matched.params...)
            result isa Union{Response,StreamResponse} || throw(TypeError(:dispatch_to_handler, Union{Response,StreamResponse}, result))
            return result
        end
        # Auto-HEAD: try GET handler, strip body
        if req.method === :head
            get_h = matched.handlers.get
            if get_h !== nothing
                resp = get_h(req, matched.params...)
                resp isa Response && return Response(resp.status, resp.headers, "")
                resp isa StreamResponse && return resp   # HEAD of streaming: pass through
            end
        end
        return Response(Plain, "405 Method Not Allowed"; status=405)
    end
    return Response(Plain, "404 Not Found"; status=404)
end

@inline function dispatch_to_handler(router::StaticRouter, req::Request)::Union{Response,StreamResponse}
    return dispatch_static(router, req)
end

# --- Static File Serving ---

"""
    serve_static!(server, conn, ev_data, method, uri) → Bool

Try to serve a static file. Returns true if handled.
"""
@inline function serve_static!(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid},
                               method::Symbol, uri::String)::Bool
    isempty(server.core.mounts) && return false

    # Don't serve static if a route explicitly handles this path
    match_route_exact(server.core.router, method, uri) !== nothing && return false

    for (dir, prefix) in server.core.mounts
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

"""
    static_file_exists(root, prefix, uri) → Bool

Check if URI maps to a real file under root. Path-traversal safe.
"""
@inline function static_file_exists(root::String, prefix::String, uri::String)::Bool
    # Strip prefix
    if prefix == "/"
        rel = uri
    elseif startswith(uri, prefix * "/") || uri == prefix
        rel = uri[length(prefix)+1:end]
    else
        return false
    end

    # Strip query string
    qi = findfirst('?', rel)
    qi !== nothing && (rel = rel[1:prevind(rel, qi)])
    rel = lstrip(rel, '/')

    candidate = normpath(joinpath(root, rel))

    # Path traversal guard
    (candidate == root || startswith(candidate, root * Base.Filesystem.path_separator)) || return false

    isfile(candidate) && return true
    isfile(candidate * ".gz") && return true
    isfile(joinpath(isempty(rel) ? root : candidate, "index.html")) && return true
    return false
end

# --- Server convenience functions ---

function route!(server::AbstractServer, method::Symbol, path::AbstractString, @nospecialize(handler::Function))
    route!(server.core.router, method, path, handler)
    return server
end

function route!(server::AbstractServer, method::AbstractString, path::AbstractString, @nospecialize(handler::Function))
    route!(server.core.router, Symbol(lowercase(method)), path, handler)
    return server
end

function ws!(server::AbstractServer, path::AbstractString; kwargs...)
    ws!(server.core.router, path; kwargs...)
    return server
end

"""
    mount!(server, directory; uri_prefix="/")

Serve static files from `directory` via Mongoose C library (Range, ETag, gzip).
"""
function mount!(server::AbstractServer, directory::AbstractString; uri_prefix::AbstractString="/")
    dir = rstrip(abspath(directory), '/')
    isdir(dir) || throw(ArgumentError("mount!: directory does not exist: $dir"))
    prefix = "/" * lstrip(rstrip(uri_prefix, '/'), '/')
    push!(server.core.mounts, (dir, prefix))
    return server
end

"""
    fail!(server, status, response)

Register a custom error response for a given HTTP status code.
"""
function fail!(server::AbstractServer, status::Integer, response::Response)
    (100 <= status <= 599) || throw(ServerError("Status must be in [100,599]"))
    server.core.errors[Int(status)] = response
    return server
end
