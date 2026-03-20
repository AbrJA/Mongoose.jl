"""
    Convenience methods — route!, ws! on server instances.
"""

# --- Delegation methods ---

function route!(server::AbstractServer, method::Symbol, path::AbstractString, handler::Function)
    http = server.core.http
    if http isa HttpRouter
        route!(http, method, path, handler)
    else
        throw(ArgumentError("Cannot add dynamic routes to a static HTTP router. Use HttpRouter() instead."))
    end
    return server
end

function ws!(server::AbstractServer, path::AbstractString; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    ws_router = server.core.ws
    if ws_router isa WsRouter
        ws!(ws_router, path; on_message=on_message, on_open=on_open, on_close=on_close)
    else
        throw(ArgumentError("Cannot add dynamic WebSocket routes to a static or missing WS router. Use WsRouter() instead."))
    end
    return server
end
