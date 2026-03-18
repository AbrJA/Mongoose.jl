"""
    WebSocket router — maps URI paths to WebSocket handler callbacks.
"""

abstract type WsRoute end

"""
    WsRouter — A path-based router for WebSocket endpoints.
    Maps URI strings to `WsHandlers` callbacks.
"""
struct WsRouter <: WsRoute
    routes::Dict{String,WsHandlers}
    WsRouter() = new(Dict{String,WsHandlers}())
end

"""
    NoWsRouter — Sentinel type indicating no WebSocket support is configured.
"""
struct NoWsRouter <: WsRoute end

"""
    ws!(server, path; on_message, on_open, on_close)

Register a WebSocket endpoint at the given `path`.

# Arguments
- `server::Server`: The server instance to register the endpoint on.
- `path::AbstractString`: The URI path for the WebSocket endpoint.
- `on_message::Function`: Called when a WebSocket message is received. Receives `WsMessage`.
- `on_open::Union{Function, Nothing}`: Called when a connection opens. Receives `HttpRequest`.
- `on_close::Union{Function, Nothing}`: Called when a connection closes. No arguments.

# Returns
The server instance for chaining.
"""
function ws!(server::Server, path::AbstractString; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    router_obj = server.core.ws_router
    router_obj.routes[path] = WsHandlers(on_open, on_message, on_close)
    return server
end
