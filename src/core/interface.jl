"""
    AbstractRouter — pluggable routing protocol.

    Any type `R <: AbstractRouter` can be supplied to `App(router=R())`.
    The transport and dispatch layers talk to routers exclusively through
    this protocol; they never inspect internal fields.

    Required protocol for HTTP dispatch:
    - `route!(r::R, method, path, handler; middleware=[], metadata=nothing) → r`
      (register an HTTP route; the router stores the handler inside an
      `Endpoint` and never interprets it)
    - `dispatch_route(r::R, method, path)`           → `nothing` or a match object
    - `get_handler(match, method)`                   → handler or `nothing`
    - `get_endpoint(match, method)`                  → `Endpoint` or `nothing`
    - `match_route_exact(r::R, method, path)`        → `nothing` or a match object

    Optional capabilities (safe defaults are provided):
    - `has_ws_routes(r::R) → Bool`                   (default: `false`)
    - `ws!(r::R, path; ...)`                         (no default)
    - `ws_endpoint(r::R, uri)`                       (default: `nothing`)
    - `route_count(r::R)`                            (default: `"?"`)

    The default implementation is `Router` in `router.jl`.

    ## Contract-by-fallback pattern

    The `AbstractRouter` protocol is enforced by *fallback methods*: calling a
    protocol function on an unimplemented router type throws a `MethodError`
    naming the missing method, so a partially-implemented router fails loudly
    instead of silently under-dispatching. Optional capabilities default to
    "not supported" rather than throwing.
"""
abstract type AbstractRouter end

# --- Required protocol: throwing fallbacks ---

function route!(router::AbstractRouter, method::Symbol, path::AbstractString,
                handler::Function; kwargs...)
    throw(MethodError(route!, (router, method, path, handler)))
end

function dispatch_route(router::AbstractRouter, method::Symbol, path::AbstractString)
    throw(MethodError(dispatch_route, (router, method, path)))
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

# --- Optional capabilities: safe defaults ---

has_ws_routes(::AbstractRouter) = false

function ws!(router::AbstractRouter, path::AbstractString; kwargs...)
    throw(MethodError(ws!, (router, path)))
end

ws_endpoint(::AbstractRouter, ::AbstractString) = nothing

route_count(::AbstractRouter) = "?"

# Closed-route profile (AOT/trim): optional; defaults to "always open".
function freeze!(router::AbstractRouter)
    throw(MethodError(freeze!, (router,)))
end
is_frozen(::AbstractRouter) = false
