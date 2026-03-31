"""
    WebSocket route registration and static dispatch stubs.
"""

# Endpoint is defined in ws/types.jl

# --- Registration ---

"""
    ws!(router, path; on_message, on_open=nothing, on_close=nothing)

Register a WebSocket endpoint.

# Callbacks
- `on_message(msg::Message) → Message | String | Vector{UInt8} | nothing` — called for each frame.
- `on_open(req::Request)` — called on upgrade with the HTTP request (optional).
- `on_close()` — called on disconnect with **no arguments** (optional).
"""
function ws!(router::Router, path::AbstractString;
    on_message::Function,
    on_open::Union{Function,Nothing}=nothing,
    on_close::Union{Function,Nothing}=nothing)
    router.ws_routes[path] = WsEndpoint(on_message=on_message, on_open=on_open, on_close=on_close)
    return router
end

# Static router WS upgrade stub — overridden by @router macro
function static_ws_upgrade(::StaticRouter, ::String)
    nothing
end
