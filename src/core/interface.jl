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

    Required protocol for WebSocket:
    - `ws!(r::R, path; on_message, on_open, on_close) → r`
    - `has_ws_routes(r::R) → Bool`
    - `ws_endpoint(r::R, uri) → Union{Nothing, WsEndpoint}`

    Optional (used only for `show` and the startup banner):
    - `route_count(r::R)` → AbstractString

    The default implementation is the trie-based `Router` in `router/trie.jl`.
"""
abstract type AbstractRouter end

# Display-only fallback for custom routers that don't implement route_count.
route_count(::AbstractRouter) = "?"