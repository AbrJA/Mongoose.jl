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

    Plain closures/functions work too: `use`/`route!` wrap them via
    `asmiddleware` (see `FunctionMiddleware`). The tag type exists so the
    pipeline can hold a typed tuple stack.
"""
abstract type AbstractMiddleware end

# --- Middleware attach hook (server-state injection) ---

"""
    attach!(middleware, server) → middleware

Optional lifecycle hook: `use` calls it when middleware is registered, so
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

    User code rarely needs this directly: `use` and `route!(; middleware=...)`
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
`FunctionMiddleware`. This is the single admission point used by `use`, by
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
middleware can live in a type parameter (`Endpoint{F,M,MD}`) and run through the
allocation-free tuple pipeline.
"""
asmiddlewaretuple(::Nothing) = ()
asmiddlewaretuple(mws::Tuple) = map(asmiddleware, mws)
asmiddlewaretuple(mws::AbstractVector) = Tuple(asmiddleware(m) for m in mws)
asmiddlewaretuple(mw) = (asmiddleware(mw),)

"""
    Next — immutable middleware continuation (internal).

    A `Function` holding the remaining global and scoped middleware stacks, the
    terminal handler, and the request, so the onion needs no per-request closure
    or cursor. The global stack runs first, then the route-scoped stack, then
    the handler.
"""
struct Next{G,S,H} <: Function
    globals::G
    scoped::S
    handler::H
    req::Request
end

@inline _run_next(n::Next{Tuple{},Tuple{}}) = n.handler(n.req)
@inline _run_next(n::Next{Tuple{},S}) where {S<:Tuple} =
    first(n.scoped)(n.req, Next((), Base.tail(n.scoped), n.handler, n.req))
@inline _run_next(n::Next{G,S}) where {G<:Tuple,S<:Tuple} =
    first(n.globals)(n.req, Next(Base.tail(n.globals), n.scoped, n.handler, n.req))

@inline (n::Next)() = _run_next(n)

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
the route-scoped stack with the same continuation — no `[global; scoped]`
array built per request.

`handler` may be any 0-arity callable (`Function` or functor) — the compiled
dispatch path passes pre-baked terminal functors.
"""
@inline runpipeline(middlewares::Tuple, req::Request, handler) =
    _run_next(Next(middlewares, (), handler, req))

@inline runpipeline(globals::Tuple, scoped::Tuple, req::Request, handler) =
    _run_next(Next(globals, scoped, handler, req))

# Compatibility: vectors are snapshotted into tuples (same typed continuation).
@inline runpipeline(middlewares::AbstractVector, req::Request, handler) =
    runpipeline(Tuple(middlewares), req, handler)

@inline runpipeline(globals::AbstractVector, scoped::AbstractVector, req::Request, handler) =
    runpipeline(Tuple(globals), Tuple(scoped), req, handler)

@inline runpipeline(globals::AbstractVector, scoped, req::Request, handler) =
    runpipeline(Tuple(globals), scoped, req, handler)

@inline runpipeline(globals, scoped::AbstractVector, req::Request, handler) =
    runpipeline(globals, Tuple(scoped), req, handler)
