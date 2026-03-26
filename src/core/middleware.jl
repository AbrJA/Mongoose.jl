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
