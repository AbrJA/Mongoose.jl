"""
    WebSocket router implementation and factories.
"""

# WsRouter and WsEndpoint are defined in types.jl

"""
    DynamicWsRouter — Top-level router for dynamic WebSocket registration.
"""
struct DynamicWsRouter <: WsRouter
    routes::Dict{String,WsEndpoint}
    DynamicWsRouter() = new(Dict{String,WsEndpoint}())
end

"""
    WsRouter() — Factory to create a DynamicWsRouter.
"""
function WsRouter()
    return DynamicWsRouter()
end

"""
    StaticWsRouter — Base type for macro-generated static WebSocket routers.
"""
abstract type StaticWsRouter <: WsRouter end

"""
    NoWsRouter — Sentinel type indicating no WebSocket support.
"""
struct NoWsRouter <: WsRouter end

# --- Registration ---

function ws!(router::DynamicWsRouter, path::AbstractString; 
             on_message::Function, 
             on_open::Union{Function,Nothing}=nothing, 
             on_close::Union{Function,Nothing}=nothing)
    router.routes[path] = WsEndpoint(on_message=on_message, on_open=on_open, on_close=on_close)
    return router
end

# (Macro-generated stubs...)
function static_ws_upgrade(::StaticWsRouter, ::String) nothing end
