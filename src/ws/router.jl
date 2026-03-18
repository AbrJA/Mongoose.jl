abstract type WsRoute end

struct WsRouter <: WsRoute
    routes::Dict{String,WsHandlers}
    WsRouter() = new(Dict{String,WsHandlers}())
end

struct NoWsRouter <: WsRoute end

"""
    ws!(server::Server, path::String; on_message::Function, on_open::Union{Function, Nothing}=nothing, on_close::Union{Function, Nothing}=nothing)
    Registers a WebSocket endpoint for a specific URI.
"""
function ws!(server::Server, path::AbstractString; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    router_obj = server.core.ws_router
    router_obj.routes[path] = WsHandlers(on_open, on_message, on_close)
    return server
end
