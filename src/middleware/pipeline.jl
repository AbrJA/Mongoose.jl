"""
    Middleware protocol — composable request/response pipeline.

    Mongoose.jl uses the "onion" model: middleware wraps around the handler.
    The new protocol supports both simple before/after hooks and full control flow.

    # Implementing Middleware

    Subtype `AbstractMiddleware` and implement the call operator:

    ```julia
    struct MyMiddleware <: AbstractMiddleware end

    function (mw::MyMiddleware)(req::Request, next::Function)
        # before logic
        response = next()  # call downstream
        # after logic (can transform response)
        return response
    end
    ```

    For simple cases, implement `before` and/or `after`:

    ```julia
    before(mw::MyMiddleware, req::Request) = nothing          # return Response to short-circuit
    after(mw::MyMiddleware, req::Request, resp) = resp        # transform response
    ```
"""
abstract type AbstractMiddleware end

# --- Default invoke via before/after hooks ---

"""
    Default call operator: routes through before() → next() → after().
    Override for full control flow (timing, error handling, etc.).
"""
function (mw::AbstractMiddleware)(req::Request, next::Function)
    result = before(mw, req)
    result !== nothing && return result
    response = next()
    return after(mw, req, response)
end

"""
    before(mw, req) → Union{Nothing, Response}

Pre-request hook. Return a `Response` to short-circuit the pipeline,
or `nothing` to continue to the next middleware.
"""
before(::AbstractMiddleware, ::Request) = nothing

"""
    after(mw, req, response) → response

Post-request hook. Can transform or replace the response.
Default: pass-through.
"""
after(::AbstractMiddleware, ::Request, response) = response

# --- Middleware Pipeline Execution ---

"""
    PathFilter — Restricts a middleware to specific URI path prefixes.
"""
struct PathFilter <: AbstractMiddleware
    inner::AbstractMiddleware
    prefixes::Vector{String}
end

function (mw::PathFilter)(req::Request, next::Function)
    uri = req.uri
    for prefix in mw.prefixes
        startswith(uri, prefix) && return mw.inner(req, next)
    end
    return next()
end

"""
    execute_pipeline(middlewares, request, handler) → Response

Execute the middleware pipeline with the given final handler.
Uses iterative construction instead of recursive closures to reduce GC pressure.
"""
@inline function execute_pipeline(middlewares::Vector{AbstractMiddleware}, req::Request,
                                  handler::Function)
    isempty(middlewares) && return handler(req)
    return _build_chain(middlewares, req, handler, 1)
end

# Recursive chain builder — each step creates one closure for `next`
@inline function _build_chain(middlewares::Vector{AbstractMiddleware}, req::Request,
                              handler::Function, idx::Int)
    if idx > length(middlewares)
        return handler(req)
    end
    mw = middlewares[idx]
    next = () -> _build_chain(middlewares, req, handler, idx + 1)
    return mw(req, next)
end

# --- Middleware registration ---

"""
    plug!(server, middleware; paths=nothing)

Register middleware. Executed in FIFO order for each request.

# Keyword Arguments
- `paths::Union{Nothing, Vector{String}}`: If set, middleware only runs for matching URI prefixes.
"""
function plug!(server, middleware::AbstractMiddleware; paths::Union{Nothing,Vector{String}}=nothing)
    if paths === nothing
        push!(server.core.middlewares, middleware)
    else
        push!(server.core.middlewares, PathFilter(middleware, paths))
    end
    return server
end
