"""
    SyncServer — Single-threaded blocking server methods.
"""

"""
    SyncServer(router=Router(); timeout=1, max_body, drain_timeout, errors)

Create a single-threaded blocking server. Compatible with `juliac --trim=safe`.

# Keyword Arguments
- `timeout::Integer`: Event-loop poll timeout in ms (default: `1`). Use `0` for minimum latency at the cost of CPU.
- `max_body::Integer`: Maximum request body size in bytes (default: 1MB).
- `drain_timeout::Integer`: Graceful shutdown drain timeout (default: 5000ms).
- `errors::Dict{Int,Response}`: Custom responses keyed by HTTP status code (`500`, `413`, `504`). See `fail!`.
"""
SyncServer(::Type{T}; kwargs...) where {T <: StaticRouter} = SyncServer(T(); kwargs...)
SyncServer(::Type{T}, config::ServerConfig) where {T <: StaticRouter} = SyncServer(T(), config)

function SyncServer(router::AbstractRouter=Router();
                    timeout::Integer=1,
                    max_body::Integer=MAX_BODY,
                    drain_timeout::Integer=DRAIN_TIMEOUT,
                    errors::Dict{Int,Response}=Dict{Int,Response}())
    c_handler = Mongoose._cfnsync(typeof(router))
    core = ServerCore(timeout, router; max_body=max_body, drain_timeout=drain_timeout, errors=errors, c_handler=c_handler)
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
        max_body    = config.max_body,
        drain_timeout = config.drain_timeout,
        errors  = config.errors
    )
end

function _init!(server::SyncServer)
    server.core.manager = Manager()
    empty!(server.core.sockets)
    return
end

function _eventloop(server::SyncServer)
    server.core.running[] = true
    mgr = server.core.manager.ptr
    timeout = server.core.timeout
    while server.core.running[]
        mg_mgr_poll(mgr, timeout)
        isempty(server.core.sockets) || mg_mgr_poll(mgr, 0)
        yield()
    end
end
