"""
    Middleware registration.
"""

"""
    use!(server, middleware) → server

Register a middleware function on the server. Middlewares execute in
the order they are registered, wrapping the final route handler.

A middleware has the signature:
    (request::AbstractRequest, params::Dict{String,String}, next) → AbstractResponse

Call `next()` to invoke the next middleware (or the route handler if last).
Return an `HttpResponse` directly to short-circuit the pipeline.

# Example
```julia
use!(server, (req, params, next) -> begin
    @info "Request: \$(req.method) \$(req.uri)"
    response = next()
    return response
end)
```
"""
function use!(server::Server, middleware::Function)
    wrapped = Middleware(middleware)
    push!(server.core.middlewares, wrapped)
    return server
end

function use!(server::Server, middleware::Middleware)
    push!(server.core.middlewares, middleware)
    return server
end
