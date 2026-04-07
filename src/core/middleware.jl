"""
    Middleware registration.
"""

"""
    plug!(server, middleware; paths=nothing)

Register a middleware. Middleware is executed in FIFO order.
Each middleware is a callable `<: AbstractMiddleware` that receives `(request, params, next)`
and must call `next()` or return early.

# Keyword Arguments
- `paths::Union{Nothing, Vector{String}}`: If provided, the middleware only runs for
  requests whose URI starts with one of the given prefixes. Requests to other paths
  skip this middleware and go directly to `next()`.

# Example
```julia
plug!(server, cors())                                          # all paths
plug!(server, api_key(keys=Set(["k"])); paths=["/api"])         # only /api/*
plug!(server, logger(); paths=["/api", "/admin"])               # selective logging
```

!!! note
    Middleware is only supported with the dynamic `route!` API.
    The static `@router` macro bypasses middleware for trim-safe compilation.
"""
function plug!(server::AbstractServer, middleware::AbstractMiddleware; paths::Union{Nothing,Vector{String}}=nothing)
    if paths === nothing
        push!(server.core.plugs, middleware)
    else
        push!(server.core.plugs, PathFilter(middleware, paths))
    end
    return server
end

"""
    PathFilter — Internal wrapper that restricts a middleware to specific URI prefixes.
"""
struct PathFilter <: AbstractMiddleware
    inner::AbstractMiddleware
    prefixes::Vector{String}
end

function (mw::PathFilter)(request::AbstractRequest, params::Vector{Any}, next)
    uri = request.uri
    for prefix in mw.prefixes
        startswith(uri, prefix) && return mw.inner(request, params, next)
    end
    return next()
end

# Server convenience — forward to underlying router
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
    mount!(server, directory)

Configure the server to serve static files from `directory` using the Mongoose
C library (`mg_http_serve_dir`). This bypasses the Julia middleware pipeline and
is handled directly on the event-loop thread for maximum performance.

Features provided by the C library at no extra cost:
- `Range` / partial content (`206`) for large files and media streaming
- `ETag` and `Last-Modified` / conditional `304 Not Modified`
- Pre-compressed `.gz` files served with `Content-Encoding: gzip`
- Directory index (`index.html`) fallback
- Automatic MIME type detection

!!! note
    Static files are served **before** the middleware pipeline. If you need
    access control on static assets, use a reverse proxy or serve them from a
    separate path that is only reachable after authentication.

# Example
```julia
mount!(server, "public")                       # GET /* → public/*
mount!(server, "public/assets"; uri_prefix="/assets")  # GET /assets/* → public/assets/*
```
"""
function mount!(server::AbstractServer, directory::AbstractString;
                    uri_prefix::AbstractString="/")
    dir = rstrip(abspath(directory), '/')
    isdir(dir) || throw(ArgumentError("mount!: directory does not exist: $dir"))
    prefix = "/" * lstrip(rstrip(uri_prefix, '/'), '/')
    push!(server.core.mounts, (dir, prefix))
    return server
end

"""
    error_response!(server, status::Int, response::Response)

Register a custom `Response` to be returned for the given HTTP status code.
Applies to: `500` (unhandled exception), `413` (body too large), `504` (timeout).

Custom 404/405 responses are better handled via a wildcard route:
```julia
route!(router, :get, "*", req -> Response(404, ContentType.html, read("404.html", String)))
```

# Example
```julia
error_response!(server, 500, Response(500, ContentType.json, \"\"\"{"error":"Internal error"}\"\"\"))
error_response!(server, 413, Response(413, ContentType.json, \"\"\"{"error":"Body too large"}\"\"\"))
```
"""
function error_response!(server::AbstractServer, status::Int, response::Response)
    server.core.errors[status] = response
    return server
end
