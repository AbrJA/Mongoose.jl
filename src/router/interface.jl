"""
    Router interface — defines the protocol that all routers must implement.
"""
abstract type AbstractRouter end

# --- Router Protocol (required methods) ---
# dispatch_route(router, method, path) → Union{Nothing, RouteMatch}
# has_ws_routes(router) → Bool
# ws_endpoint(router, uri) → Union{Nothing, WsEndpoint}
# match_route_exact(router, method, path) → Union{Nothing, RouteMatch}

# Route count (for logging)
route_count(::AbstractRouter) = "unknown"
