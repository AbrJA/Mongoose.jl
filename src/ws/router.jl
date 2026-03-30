"""
    WebSocket route registration and static dispatch stubs.
"""

# Endpoint is defined in ws/types.jl

# --- Registration ---

function ws!(router::Router, path::AbstractString;
    on_message::Function,
    on_open::Union{Function,Nothing}=nothing,
    on_close::Union{Function,Nothing}=nothing)
    router.ws_routes[path] = Endpoint(on_message=on_message, on_open=on_open, on_close=on_close)
    return router
end

# Static router WS upgrade stub — overridden by @router macro
function static_ws_upgrade(::StaticRouter, ::String)
    nothing
end
