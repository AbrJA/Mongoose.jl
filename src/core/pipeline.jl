"""
    Middleware protocol — composable request/response pipeline.

    Mongoose.jl uses the "onion" model: middleware wraps around the handler.

    # Implementing Middleware

    Subtype `AbstractMiddleware` and implement the call operator:

    ```julia
    struct MyMiddleware <: AbstractMiddleware end

    function (mw::MyMiddleware)(req::Request, next::Function)
        # before logic
        response = next()  # call downstream
        # after logic
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

function (mw::AbstractMiddleware)(req::Request, next::Function)
    result = before(mw, req)
    result !== nothing && return result
    response = next()
    return after(mw, req, response)
end

before(::AbstractMiddleware, ::Request) = nothing
after(::AbstractMiddleware, ::Request, response) = response

# --- PathFilter: restricts middleware to specific URI prefixes ---

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

# --- FunctionMiddleware: allow plain callables as middleware ---

"""
    FunctionMiddleware{F} — adapter that lets any callable `f(req, next)` act
    as a middleware without subtyping `AbstractMiddleware`.

    User code rarely needs this directly: `use!` and `route!(; middleware=...)`
    accept plain closures/functions and wrap them automatically.
"""
struct FunctionMiddleware{F} <: AbstractMiddleware
    f::F
end

function (mw::FunctionMiddleware)(req::Request, next::Function)
    return mw.f(req, next)
end

as_middleware(mw::AbstractMiddleware) = mw
as_middleware(mw) = FunctionMiddleware(mw)

# --- Pipeline execution ---

"""
    execute_pipeline(middlewares, request, handler) → Response
"""
@inline function execute_pipeline(middlewares::Vector{AbstractMiddleware}, req::Request,
                                  handler::Function)
    isempty(middlewares) && return handler(req)
    return _build_chain(middlewares, req, handler, 1)
end

@inline function _build_chain(middlewares::Vector{AbstractMiddleware}, req::Request,
                              handler::Function, idx::Int)
    idx > length(middlewares) && return handler(req)
    mw = middlewares[idx]
    next = () -> _build_chain(middlewares, req, handler, idx + 1)
    return mw(req, next)
end
