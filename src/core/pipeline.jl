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

Run the middleware onion around `handler`: each middleware receives
`(request, next)`; `next` advances to the following middleware and finally the
handler. Middleware may short-circuit by returning without calling `next`.

The chain is executed with a **single closure** plus a mutable cursor instead
of one closure per middleware per request (`_build_chain` recursion), keeping
the per-request allocation constant regardless of stack depth.
"""
@inline function execute_pipeline(middlewares::Vector{AbstractMiddleware}, req::Request,
                                  handler::Function)
    n = length(middlewares)
    n == 0 && return handler(req)
    cell = _ChainCursor(0)
    next = () -> begin
        cell.i += 1
        cell.i <= n || return handler(req)
        middlewares[cell.i](req, next)
    end
    return next()
end

mutable struct _ChainCursor
    i::Int
end
