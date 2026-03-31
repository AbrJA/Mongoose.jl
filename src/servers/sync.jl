"""
    SyncServer — Single-threaded blocking server methods.
"""

"""
    SyncServer(router=Router(); timeout=1, max_body_size, drain_timeout_ms, on_error)

Create a single-threaded blocking server. Compatible with `juliac --trim=safe`.

# Keyword Arguments
- `timeout::Integer`: Event-loop poll timeout in ms (default: `1`). Use `0` for minimum latency at the cost of CPU.
- `max_body_size::Integer`: Maximum request body size in bytes (default: 1MB).
- `drain_timeout_ms::Integer`: Graceful shutdown drain timeout (default: 5000ms).
- `on_error::Union{Nothing,Function}`: Custom error handler `(req, exception) → Response` (default: `nothing`).
"""
SyncServer(::Type{T}; kwargs...) where {T <: StaticRouter} = SyncServer(T(); kwargs...)

function SyncServer(router::AbstractRouter=Router();
                    timeout::Integer=1,
                    max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                    drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS,
                    on_error::Union{Nothing,Function}=nothing)
    c_handler = Mongoose._cfnsync(typeof(router))
    core = ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, on_error=on_error, c_handler=c_handler)
    server = SyncServer{typeof(router)}(core)
    finalizer(_teardown!, server)
    return server
end

function _init!(server::SyncServer)
    server.core.manager = Manager()
    empty!(server.core.ws_connections)
    return
end

function _eventloop(server::SyncServer)
    server.core.running[] = true
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        yield()
    end
end
