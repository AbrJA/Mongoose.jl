"""
    Middleware protocol — composable request/response pipeline.

    Middleware is a callable `(req, next) → response` that wraps around the
    handler ("onion" model). `req` is the `Request`, `next` advances to the
    following middleware (and finally the handler); returning a `Response`
    without calling `next` short-circuits.

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

    Plain closures/functions work too: `use!`/`route!` wrap them via
    `asmiddleware` (see `FunctionMiddleware`). The tag type exists so the
    pipeline can hold a typed stack (`Vector{AbstractMiddleware}`).
"""
abstract type AbstractMiddleware end

# --- PathFilter: restricts middleware to specific URI prefixes ---

struct PathFilter <: AbstractMiddleware
    inner::AbstractMiddleware
    prefixes::Vector{String}
end

function (mw::PathFilter)(req::Request, next::Function)
    path = req.path
    for prefix in mw.prefixes
        # Segment-boundary match: "/api" matches "/api" and "/api/x", not "/apixyz".
        (path == prefix || startswith(path, prefix * "/")) && return mw.inner(req, next)
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

"""
    asmiddleware(mw) → AbstractMiddleware

Normalize any middleware into an `AbstractMiddleware`: `AbstractMiddleware`
instances pass through; any other callable `f(req, next)` is wrapped in a
`FunctionMiddleware`. This is the single admission point used by `use!`, by
`route!`/`group` `middleware=` metadata, and by `Endpoint`s.
"""
asmiddleware(mw::AbstractMiddleware) = mw
asmiddleware(mw) = FunctionMiddleware(mw)

"""
    asmiddlewares(input) → Vector{AbstractMiddleware}

Normalize middleware input into a `Vector{AbstractMiddleware}`: `nothing` →
empty, a single middleware (or plain callable) → one entry, a vector/tuple →
one entry per element. Each element goes through [`asmiddleware`](@ref).
"""
asmiddlewares(::Nothing) = AbstractMiddleware[]
asmiddlewares(mws::AbstractVector) = AbstractMiddleware[asmiddleware(m) for m in mws]
asmiddlewares(mws::Tuple) = AbstractMiddleware[asmiddleware(m) for m in mws]
asmiddlewares(mw) = AbstractMiddleware[asmiddleware(mw)]

# --- Pipeline execution ---

"""
    runpipeline(middlewares, request, handler) → Response
    runpipeline(globals, scoped, request, handler) → Response

Run the middleware onion around `handler`: each middleware receives
`(request, next)`; `next` advances to the following middleware and finally the
handler. Middleware may short-circuit by returning without calling `next`.

The chain is executed with a **single closure** plus a mutable cursor instead of
one closure per middleware per request, keeping the per-request allocation
constant regardless of stack depth. The four-argument form walks the baked
app-global stack `globals` and the route-scoped stack `scoped` with **one
cursor over their virtual concatenation** — no `[global; scoped]` array built
per request.

`handler` may be any 0-arity callable (`Function` or functor) — the compiled
dispatch path passes pre-baked terminal functors.
"""
@inline function runpipeline(middlewares, req::Request,
                                  handler)
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

@inline function runpipeline(globals, scoped::AbstractVector{<:AbstractMiddleware},
                                  req::Request, handler)
    ng, ns = length(globals), length(scoped)
    total = ng + ns
    total == 0 && return handler(req)
    cell = _ChainCursor(0)
    next = () -> begin
        cell.i += 1
        cell.i <= ng && return globals[cell.i](req, next)
        cell.i <= total || return handler(req)
        scoped[cell.i - ng](req, next)
    end
    return next()
end

mutable struct _ChainCursor
    i::Int
end
