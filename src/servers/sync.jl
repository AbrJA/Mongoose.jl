"""
    Server — Single-threaded blocking server methods.
"""

"""
    Server(router=Router(); poll_timeout=1, max_body, drain_timeout, errors)

Create a single-threaded blocking server. Compatible with `juliac --trim=safe`.

# Keyword Arguments
- `poll_timeout::Integer`: Event-loop poll timeout in ms (default: `1`). Use `0` for minimum latency at the cost of CPU.
- `max_body::Integer`: Maximum request body size in bytes (default: 1MB).
- `drain_timeout::Integer`: Graceful shutdown drain timeout (default: 5000ms).
- `errors::Dict{Int,Response}`: Custom responses keyed by HTTP status code (`500`, `413`, `504`). See `fail!`.
"""
Server(::Type{T}; kwargs...) where {T <: StaticRouter} = Server(T(); kwargs...)
Server(::Type{T}, config::Config) where {T <: StaticRouter} = Server(T(), config)

function Server(router::AbstractRouter=Router();
                    poll_timeout::Integer=1,
                    max_body::Integer=MAX_BODY,
                    drain_timeout::Integer=DRAIN_TIMEOUT,
                    errors::Dict{Int,Response}=Dict{Int,Response}())
    c_handler = Mongoose._cfnsync(typeof(router))
    core = ServerCore(poll_timeout, router; max_body=max_body, drain_timeout=drain_timeout, errors=errors, c_handler=c_handler)
    server = Server{typeof(router)}(core)
    finalizer(_teardown!, server)
    return server
end

"""
    Server(router, config::Config)

Create a `Server` from a [`Config`](@ref) struct.
"""
function Server(router::AbstractRouter, config::Config)
    return Server(router;
        poll_timeout          = config.poll_timeout,
        max_body    = config.max_body,
        drain_timeout = config.drain_timeout,
        errors  = config.errors
    )
end

function _init!(server::Server)
    server.core.manager = Manager()
    empty!(server.core.clients)
    return
end

function _eventloop(server::Server)
    mgr = server.core.manager.ptr
    timeout = server.core.poll_timeout
    while server.core.running[]
        mg_mgr_poll(mgr, timeout)
        isempty(server.core.clients) || mg_mgr_poll(mgr, 0)
        yield()
    end
end
