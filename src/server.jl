"""
    User-facing Server — unified API that wraps AsyncServer / SyncServer internals.
"""
mutable struct Server
    http::AbstractHttpRouter
    ws::AbstractWsRouter
    middlewares::Vector{Function}
    timeout::Int
    max_body_size::Int
    drain_timeout_ms::Int
    nqueue::Int
    _runtime::Union{Nothing, AbstractServer}
end

"""
    Server(router=HttpRouter(); ws_router=NoWsRouter(), timeout, max_body_size, drain_timeout_ms, nqueue)

Create a server with the given HTTP and WebSocket routers.
Routers can be either dynamic or static (generated via macros).
`HttpRouter()` and `WsRouter()` create dynamic routers.
"""
function Server(router::AbstractHttpRouter=HttpRouter();
                ws_router::AbstractWsRouter=NoWsRouter(),
                timeout::Integer=0,
                max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS,
                nqueue::Integer=1024)
    return Server(router, ws_router, Function[], Int(timeout),
                  Int(max_body_size), Int(drain_timeout_ms), Int(nqueue), nothing)
end

# --- Delegation methods ---

function route!(server::Server, method::Symbol, path::AbstractString, handler::Function)
    if server.http isa HttpRouter
        route!(server.http, method, path, handler)
    else
        throw(ArgumentError("Cannot add dynamic routes to a static HTTP router. Use HttpRouter() instead."))
    end
    return server
end

function ws!(server::Server, path::AbstractString; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    if server.ws isa WsRouter
        ws!(server.ws, path; on_message=on_message, on_open=on_open, on_close=on_close)
    else
        throw(ArgumentError("Cannot add dynamic WebSocket routes to a static or missing WS router. Use WsRouter() instead."))
    end
    return server
end

function use!(server::Server, middleware::Function)
    push!(server.middlewares, middleware)
    return server
end

# --- Lifecycle ---

function start!(server::Server; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=true, workers::Integer=0)
    server._runtime !== nothing && throw(ServerError("Server is already running. Call shutdown! first."))

    if workers > 0
        runtime = build_AsyncServer(server.http, server.ws, C_NULL,
                                    server.timeout, workers, server.nqueue,
                                    server.max_body_size, server.drain_timeout_ms)
    else
        runtime = build_SyncServer(server.http, server.ws, C_NULL,
                                   server.timeout, server.max_body_size,
                                   server.drain_timeout_ms)
    end

    append!(runtime.core.middlewares, server.middlewares)

    server._runtime = runtime
    start!(runtime; host=host, port=port, blocking=blocking)
    return server
end

function shutdown!(server::Server)
    runtime = server._runtime
    if runtime === nothing
        @info "Server not running. Nothing to do."
        return
    end
    shutdown!(runtime)
    server._runtime = nothing
    return
end
