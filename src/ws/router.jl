"""
    WebSocket router — maps URI paths to WebSocket handler callbacks.
"""

abstract type AbstractWsRoute end

"""
    WsRouter — A path-based router for WebSocket endpoints.
    Maps URI strings to `WsHandlers` callbacks.
"""
struct WsRouter <: AbstractWsRoute
    routes::Dict{String,WsHandlers}
    WsRouter() = new(Dict{String,WsHandlers}())
end

"""
    NoWsRouter — Sentinel type indicating no WebSocket support is configured.
"""
struct NoWsRouter <: AbstractWsRoute end

"""
    ws!(server, path; on_message, on_open, on_close)

Register a WebSocket endpoint at the given `path`.

# Arguments
- `server::AbstractServer`: The server instance to register the endpoint on.
- `path::AbstractString`: The URI path for the WebSocket endpoint.
- `on_message::Function`: Called when a WebSocket message is received. Receives `WsMessage`.
- `on_open::Union{Function, Nothing}`: Called when a connection opens. Receives `HttpRequest`.
- `on_close::Union{Function, Nothing}`: Called when a connection closes. No arguments.

# Returns
The server instance for chaining.
"""
function ws!(server::AbstractServer, path::AbstractString; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    router_obj = server.core.ws_router
    if router_obj isa NoWsRouter
        throw(ArgumentError("WebSocket support not configured. Pass WsRouter() when creating the server, e.g. AsyncServer(NoApp(), WsRouter())"))
    end
    router_obj.routes[path] = WsHandlers(on_message=on_message, on_open=on_open, on_close=on_close)
    return server
end
