"""
    Middleware registration.
"""

"""
    use!(server, middleware)

Register a middleware. Middleware is executed in FIFO order.
Each middleware is a callable `<: Middleware` that receives `(request, params, next)`
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
function use!(server::AbstractServer, middleware::Middleware)
    push!(server.core.middlewares, middleware)
    return server
end
