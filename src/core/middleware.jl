"""
    Middleware registration.
"""

"""
    use!(server, middleware)

Register a middleware function. Middleware is executed in FIFO order.
Each middleware receives `(request, params, next)` and must call `next()` or return early.

# Example
```julia
use!(server, (req, params, next) -> begin
    @info "Request: \$(req.method) \$(req.uri)"
    next()
end)
```

!!! note
    Middleware is only supported with the dynamic `route!` API.
    The static `@routes` macro bypasses middleware for trim-safe compilation.
"""
function use!(server::Server, middleware::Function)
    push!(server.core.middlewares, middleware)
    return server
end
