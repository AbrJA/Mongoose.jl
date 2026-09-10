"""
    AbstractRouter — pluggable routing protocol.

    Any type `R <: AbstractRouter` can be supplied to `App(router=R())`.
    The transport and dispatch layers talk to routers exclusively through
    this protocol; they never inspect internal fields.

    Required protocol for HTTP dispatch:
    - `route!(r::R, method, path, handler; middleware=[], metadata=nothing) → r`
      (register an HTTP route; the router stores the handler inside an
      `Endpoint` and never interprets it)
    - `match_route(r::R, method, path)`                → a `RouteResult`
      (`Matched` / `NotFound` / `MethodNotAllowed{allowed}` — 404/405 and the
      `Allow` set are resolved by the router at match time)
    - `match_route_exact(r::R, method, path)`          → `nothing` or a `Matched`
      (no `"*"` fallback — route ownership check for static serving)
    - `get_handler(match, method)` / `get_endpoint(match, method)` — work on
      any `Matched`, including custom routers' matches and `SingleEndpoint`

    Custom routers return a `RouteResult` from `match_route`. Returning a
    `Matched` directly is enough: wrap the endpoint with
    `SingleEndpoint(ep, method)` as the match's `handlers` value.

    Optional capabilities (safe defaults are provided):
    - `has_ws_routes(r::R) → Bool`                   (default: `false`)
    - `ws!(r::R, path; ...)`                         (no default)
    - `ws_endpoint(r::R, uri)`                       (default: `nothing`)
    - `route_count(r::R)`                            (default: `0`)

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
    RouteResult — outcome of `match_route`: `Matched`, `NotFound`, or
    `MethodNotAllowed{allowed}` (the last carries the route's method bitmask,
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
struct NotFound <: RouteResult end

"""
    MethodNotAllowed{allowed::UInt8} <: RouteResult

The path matched but the method isn't registered; `allowed` is a bitmask of
served methods (HEAD is implied by GET). Serialize with
`allow_from_bitmask` for the RFC 9110 §15.5.6 `Allow` header.
"""
struct MethodNotAllowed <: RouteResult
    allowed::UInt8
end

"""
    SingleEndpoint — minimal "handlers" carrier for custom routers that don't
    track per-method maps. `get_handler`/`get_endpoint` answer for exactly the
    one method the endpoint serves.
"""
struct SingleEndpoint{E,S}
    endpoint::E
    method::S
end
get_endpoint(se::SingleEndpoint, m::Symbol) = m == se.method ? se.endpoint : nothing
get_handler(se::SingleEndpoint, m::Symbol) =
    m == se.method ? se.endpoint.handler : nothing

# --- Required protocol: throwing fallbacks ---

function route!(router::AbstractRouter, method::Symbol, path::AbstractString,
                handler::Function; kwargs...)
    throw(MethodError(route!, (router, method, path, handler)))
end

function match_route(router::AbstractRouter, method::Symbol, path::AbstractString)
    throw(MethodError(match_route, (router, method, path)))
end

function match_route_exact(router::AbstractRouter, method::Symbol, path::AbstractString)
    throw(MethodError(match_route_exact, (router, method, path)))
end

function get_handler(matched, method::Symbol)
    throw(MethodError(get_handler, (matched, method)))
end

function get_endpoint(matched, method::Symbol)
    throw(MethodError(get_endpoint, (matched, method)))
end

# Matched exposes the handlers accessors too (introspection + tests).
@inline get_handler(m::Matched, method::Symbol) = get_handler(m.handlers, method)
@inline get_endpoint(m::Matched, method::Symbol) = get_endpoint(m.handlers, method)

# --- Optional capabilities: safe defaults ---

has_ws_routes(::AbstractRouter) = false

function ws!(router::AbstractRouter, path::AbstractString; kwargs...)
    throw(MethodError(ws!, (router, path)))
end

ws_endpoint(::AbstractRouter, ::AbstractString) = nothing

route_count(::AbstractRouter) = 0

# Closed-route profile (AOT/trim): optional; defaults to "always open".
function freeze!(router::AbstractRouter)
    throw(MethodError(freeze!, (router,)))
end
isfrozen(::AbstractRouter) = false

# ── Compiled-dispatch capability (optional) ──────────────────────────────

"""
    terminal_for(router, request) → Union{Nothing,Function}

Optional compiled-dispatch capability. A frozen `Router` that compiled its
route table returns a **pre-built terminal** `(req) → Response` for the
request (scoped middleware already fused, handler call statically typed);
`nothing` means "fall back to the generic dispatch path".

This is the contract-by-fallback seam that lets the pipeline skip the
per-request closure/concat allocation when the router is compiled, without
forcing every router implementation to understand compilation.
"""
terminal_for(::AbstractRouter, ::Request) = nothing
