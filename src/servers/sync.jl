"""
    SyncServer — Single-threaded blocking server methods.
"""

"""
    SyncServer(router=Router(); timeout=1, max_body_size, drain_timeout_ms, error_responses)

Create a single-threaded blocking server. Compatible with `juliac --trim=safe`.

# Keyword Arguments
- `timeout::Integer`: Event-loop poll timeout in ms (default: `1`). Use `0` for minimum latency at the cost of CPU.
- `max_body_size::Integer`: Maximum request body size in bytes (default: 1MB).
- `drain_timeout_ms::Integer`: Graceful shutdown drain timeout (default: 5000ms).
- `error_responses::Dict{Int,Response}`: Custom responses keyed by HTTP status code (`500`, `413`, `504`). See `error_response!`.
"""
SyncServer(::Type{T}; kwargs...) where {T <: StaticRouter} = SyncServer(T(); kwargs...)
SyncServer(::Type{T}, config::ServerConfig) where {T <: StaticRouter} = SyncServer(T(), config)

function SyncServer(router::AbstractRouter=Router();
                    timeout::Integer=1,
                    max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                    drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS,
                    error_responses::Dict{Int,Response}=Dict{Int,Response}())
    c_handler = Mongoose._cfnsync(typeof(router))
    core = ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, error_responses=error_responses, c_handler=c_handler)
    server = SyncServer{typeof(router)}(core)
    finalizer(_teardown!, server)
    return server
end

"""
    SyncServer(router, config::ServerConfig)

Create a `SyncServer` from a [`ServerConfig`](@ref) struct.
"""
function SyncServer(router::AbstractRouter, config::ServerConfig)
    return SyncServer(router;
        timeout          = config.timeout,
        max_body_size    = config.max_body_size,
        drain_timeout_ms = config.drain_timeout_ms,
        error_responses  = config.error_responses
    )
end

function _init!(server::SyncServer)
    server.core.manager = Manager()
    empty!(server.core.ws_connections)
    return
end

function _eventloop(server::SyncServer)
    server.core.running[] = true
    mgr = server.core.manager.ptr
    timeout = server.core.timeout
    while server.core.running[]
        mg_mgr_poll(mgr, timeout)
        isempty(server.core.ws_connections) || mg_mgr_poll(mgr, 0)
        yield()
    end
end
