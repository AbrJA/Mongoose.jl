"""
    AbstractRouter — pluggable routing protocol.

    Any type `R <: AbstractRouter` can be supplied to `App(router=R())`.
    The transport and dispatch layers talk to routers exclusively through
    this protocol; they never inspect internal fields.

    Required protocol for HTTP dispatch:
    - `route!(r::R, method, path, handler; middleware=[], metadata=nothing) → r`
      (register an HTTP route; the router stores the handler inside an
      `Endpoint` and never interprets it)
    - `matchroute(r::R, method, path)`                → a `RouteResult`
      (`Matched` / `NoMatch` / `WrongMethod{allowed}` — 404/405 and the
      `Allow` set are resolved by the router at match time)
    - `hasroute(r::R, path)`                  → `Bool` (path owned, catch-all excluded)
      (no `"*"` fallback — route ownership check for static serving)
    - `gethandler(match, method)` / `getendpoint(match, method)` — work on
      any `Matched`, including custom routers' matches and `SingleEndpoint`

    Custom routers return a `RouteResult` from `matchroute`. Returning a
    `Matched` directly is enough: wrap the endpoint with
    `SingleEndpoint(ep, method)` as the match's `handlers` value.

    Optional capabilities (safe defaults are provided):
    - `haswsroutes(r::R) → Bool`                   (default: `false`)
    - `ws!(r::R, path; ...)`                         (no default)
    - `wsendpoint(r::R, uri)`                       (default: `nothing`)
    - `length(r::R)`                            (default: `0`)

    The default implementation is `Router` in `router.jl`.

    ## Contract-by-fallback pattern

    The `AbstractRouter` protocol is enforced by *fallback methods*: calling a
    protocol function on an unimplemented router type throws a `MethodError`
    naming the missing method, so a partially-implemented router fails loudly
    instead of silently under-dispatching. Optional capabilities default to
    "not supported" rather than throwing.
"""
abstract type AbstractRouter end

# ── RouteResult — the exhaustive router match (Ciro/Keel-style ADT) ──────────

"""
    RouteResult — outcome of `matchroute`: `Matched`, `NoMatch`, or
    `WrongMethod{allowed}` (the last carries the route's method bitmask,
    so 405 `Allow` needs no secondary lookup).
"""
abstract type RouteResult end

"""
    Matched{endpoint,handlers,params} <: RouteResult

A successful route match. `endpoint` is the `Endpoint` for the requested
method, `handlers` carries the route's method information (a `MethodMap`, or
`SingleEndpoint` for routers with one handler), and `params` is the typed
parameter tuple.
"""
struct Matched{E,P,H} <: RouteResult
    endpoint::E
    handlers::H
    params::P
end

"""No route matched the path."""
struct NoMatch <: RouteResult end

"""
    WrongMethod{allowed::UInt8} <: RouteResult

The path matched but the method isn't registered; `allowed` is a bitmask of
served methods (HEAD is implied by GET). Serialize with
`allow_from_bitmask` for the RFC 9110 §15.5.6 `Allow` header.
"""
struct WrongMethod <: RouteResult
    allowed::UInt8
end

"""
    SingleEndpoint — minimal "handlers" carrier for custom routers that don't
    track per-method maps. `gethandler`/`getendpoint` answer for exactly the
    one method the endpoint serves.
"""
struct SingleEndpoint{E,S}
    endpoint::E
    method::S
end
getendpoint(se::SingleEndpoint, m::Symbol) = m == se.method ? se.endpoint : nothing
gethandler(se::SingleEndpoint, m::Symbol) =
    m == se.method ? se.endpoint.handler : nothing

# --- Required protocol: throwing fallbacks ---

function route!(router::AbstractRouter, method::Symbol, path::AbstractString,
                handler::Function; kwargs...)
    throw(MethodError(route!, (router, method, path, handler)))
end

function matchroute(router::AbstractRouter, method::Symbol, path::AbstractString)
    throw(MethodError(matchroute, (router, method, path)))
end

function hasroute(router::AbstractRouter, path::AbstractString)
    throw(MethodError(hasroute, (router, path)))
end

function gethandler(matched, method::Symbol)
    throw(MethodError(gethandler, (matched, method)))
end

function getendpoint(matched, method::Symbol)
    throw(MethodError(getendpoint, (matched, method)))
end

# Matched exposes the handlers accessors too (introspection + tests).
@inline gethandler(m::Matched, method::Symbol) = gethandler(m.handlers, method)
@inline getendpoint(m::Matched, method::Symbol) = getendpoint(m.handlers, method)

# --- Optional capabilities: safe defaults ---

haswsroutes(::AbstractRouter) = false

function ws!(router::AbstractRouter, path::AbstractString; kwargs...)
    throw(MethodError(ws!, (router, path)))
end

wsendpoint(::AbstractRouter, ::AbstractString) = nothing

Base.length(::AbstractRouter) = 0

# Closed-route profile (AOT/trim): optional; defaults to "always open".
function freeze!(router::AbstractRouter)
    throw(MethodError(freeze!, (router,)))
end
isfrozen(::AbstractRouter) = false

# ── Compiled-dispatch capability (optional) ──────────────────────────────

"""
    terminalfor(router, request) → Union{Nothing,Function}

Optional compiled-dispatch capability. A frozen `Router` that compiled its
route table returns a **pre-built terminal** `(req) → Response` for the
request (scoped middleware already fused, handler call statically typed);
`nothing` means "fall back to the generic dispatch path".

This is the contract-by-fallback seam that lets the pipeline skip the
per-request closure/concat allocation when the router is compiled, without
forcing every router implementation to understand compilation.
"""
terminalfor(::AbstractRouter, ::Request) = nothing
