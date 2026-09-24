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

# --- Middleware attach hook (server-state injection) ---

"""
    attach!(middleware, server) → middleware

Optional lifecycle hook: `use!` calls it when middleware is registered, so
middleware that needs server state (metrics gauges, readiness checks) can
capture a reference. Default is a no-op.
"""
attach!(mw, server) = mw

# --- PathFilter: restricts middleware to specific URI prefixes ---

struct PathFilter{M} <: AbstractMiddleware
    inner::M
    prefixes::Vector{String}
end

attach!(mw::PathFilter, server) = (attach!(mw.inner, server); mw)

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

"""
    asmiddlewaretuple(input) → Tuple

Like [`asmiddlewares`](@ref) but returns an immutable tuple, so route-scoped
middleware can live in a type parameter (`Endpoint{F,M}`) and run through the
allocation-free tuple pipeline.
"""
asmiddlewaretuple(::Nothing) = ()
asmiddlewaretuple(mws::Tuple) = map(asmiddleware, mws)
asmiddlewaretuple(mws::AbstractVector) = Tuple(asmiddleware(m) for m in mws)
asmiddlewaretuple(mw) = (asmiddleware(mw),)

"""
    Next — immutable middleware continuation (internal).

    A `Function` holding the remaining middleware tuple, the terminal handler,
    and the request, so the onion needs no per-request closure.
"""
struct Next{M,H} <: Function
    mws::M
    handler::H
    req::Request
end

@inline (n::Next{Tuple{}})() = n.handler(n.req)
@inline (n::Next)() = first(n.mws)(n.req, Next(Base.tail(n.mws), n.handler, n.req))

"""
    runpipeline(middlewares, request, handler) → Response
    runpipeline(globals, scoped, request, handler) → Response

Run the middleware onion around `handler`: each middleware receives
`(request, next)`; `next` advances to the following middleware and finally the
handler. Middleware may short-circuit by returning without calling `next`.

The tuple form (the compiled/production path, where route-scoped middleware is
already fused into the terminal) walks the baked stack with an immutable
callable continuation — `Next` is a `Function`, so the `(req, next)` contract
is unchanged, but no closure or cursor is allocated per request.

The four-argument form (generic/dev path) walks the baked app-global stack and
the route-scoped stack with **one cursor over their virtual concatenation** —
no `[global; scoped]` array built per request.

`handler` may be any 0-arity callable (`Function` or functor) — the compiled
dispatch path passes pre-baked terminal functors.
"""
@inline runpipeline(middlewares::Tuple, req::Request, handler) =
    Next(middlewares, handler, req)()

# Fallback for vector stacks (e.g. a compiled route's scoped wrapper): same
# onion with one closure + cursor per request.
@inline function runpipeline(middlewares, req::Request, handler)
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

@inline function runpipeline(globals, scoped,
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
