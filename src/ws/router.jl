"""
    WebSocket router implementation and factories.
"""

# WsRouter and WsEndpoint are defined in types.jl

"""
    WsRouter — Dynamic WebSocket router.
"""
struct WsRouter <: AbstractWsRouter
    routes::Dict{String,WsEndpoint}
    WsRouter() = new(Dict{String,WsEndpoint}())
end

"""
    StaticWsRouter — Base type for macro-generated static WebSocket routers.
"""
abstract type StaticWsRouter <: AbstractWsRouter end

"""
    NoWsRouter — Sentinel type indicating no WebSocket support.
"""
struct NoWsRouter <: AbstractWsRouter end

# --- Registration ---

function ws!(router::WsRouter, path::AbstractString;
             on_message::Function,
             on_open::Union{Function,Nothing}=nothing,
             on_close::Union{Function,Nothing}=nothing)
    router.routes[path] = WsEndpoint(on_message=on_message, on_open=on_open, on_close=on_close)
    return router
end

# (Macro-generated stubs...)
function static_ws_upgrade(::StaticWsRouter, ::String) nothing end
