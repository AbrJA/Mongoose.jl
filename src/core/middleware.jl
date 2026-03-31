"""
    Middleware registration.
"""

"""
    use!(server, middleware)

Register a middleware. Middleware is executed in FIFO order.
Each middleware is a callable `<: AbstractMiddleware` that receives `(request, params, next)`
and must call `next()` or return early.

# Example
```julia
use!(server, cors(origins="https://myapp.com"))
use!(server, logger())
```

!!! note
    Middleware is only supported with the dynamic `route!` API.
    The static `@router` macro bypasses middleware for trim-safe compilation.
"""
function use!(server::AbstractServer, middleware::AbstractMiddleware)
    push!(server.core.middlewares, middleware)
    return server
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
