"""
    Middleware registration.
"""

"""
    use!(server, middleware; paths=nothing)

Register a middleware. Middleware is executed in FIFO order.
Each middleware is a callable `<: AbstractMiddleware` that receives `(request, params, next)`
and must call `next()` or return early.

# Keyword Arguments
- `paths::Union{Nothing, Vector{String}}`: If provided, the middleware only runs for
  requests whose URI starts with one of the given prefixes. Requests to other paths
  skip this middleware and go directly to `next()`.

# Example
```julia
use!(server, cors())                                          # all paths
use!(server, api_key(keys=Set(["k"])); paths=["/api"])         # only /api/*
use!(server, logger(); paths=["/api", "/admin"])               # selective logging
```

!!! note
    Middleware is only supported with the dynamic `route!` API.
    The static `@router` macro bypasses middleware for trim-safe compilation.
"""
function use!(server::AbstractServer, middleware::AbstractMiddleware; paths::Union{Nothing,Vector{String}}=nothing)
    if paths === nothing
        push!(server.core.middlewares, middleware)
    else
        push!(server.core.middlewares, PathFilter(middleware, paths))
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
    serve_dir!(server, directory)

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
serve_dir!(server, "public")          # serve files from ./public/
serve_dir!(server, "/var/www/html")   # absolute path
```
"""
function serve_dir!(server::AbstractServer, directory::AbstractString)
    dir = rstrip(abspath(directory), '/')
    isdir(dir) || throw(ArgumentError("serve_dir!: directory does not exist: \$dir"))
    server.core.static_dir = dir
    return server
end

"""
    on_error!(server, handler)

Set a custom error handler. `handler` receives `(request, exception)` and
must return a `Response`. If the handler itself throws, a generic 500 is sent.

# Example
```julia
on_error!(server, (req, e) -> Response(500, ContentType.json,
    JSON.json(Dict("error" => string(e), "uri" => req.uri))))
```
"""
function on_error!(server::AbstractServer, @nospecialize(handler::Function))
    server.core.on_error = handler
    return server
end
