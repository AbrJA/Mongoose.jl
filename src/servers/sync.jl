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
                    ws_idle_timeout::Integer=0,
                    errors::Dict{Int,Response}=Dict{Int,Response}())
    c_handler = Mongoose._cfnsync(typeof(router))
    core = ServerCore(poll_timeout, router; max_body=max_body, drain_timeout=drain_timeout,
                      ws_idle_timeout=ws_idle_timeout, errors=errors, c_handler=c_handler)
    server = Server{typeof(router)}(core)
    finalizer(_teardown!, server)
    return server
end

"""
    Server(router, config::Config)

Create a `Server` from a [`Config`](@ref) struct.

!!! note
    `request_timeout` is ignored by `Server` (single-threaded, no task to enforce it).
    Use `Async` for per-request timeouts.
"""
function Server(router::AbstractRouter, config::Config)
    _validate(config)
    config.request_timeout > 0 && @log_warn "request_timeout=" * string(config.request_timeout) * " ignored by Server (use Async for per-request timeouts)"
    return Server(router;
        poll_timeout          = config.poll_timeout,
        max_body    = config.max_body,
        drain_timeout = config.drain_timeout,
        ws_idle_timeout = config.ws_idle_timeout,
        errors  = config.errors
    )
end

function _init!(server::Server)
    server.core.manager = Manager()
    empty!(server.core.ws_clients)
    return
end

function _eventloop(server::Server)
    mgr = server.core.manager.ptr
    timeout = server.core.poll_timeout
    last_sweep = time()
    while server.core.running[]
        mg_mgr_poll(mgr, timeout)
        isempty(server.core.ws_clients) || mg_mgr_poll(mgr, 0)
        if server.core.ws_idle_timeout > 0 && !isempty(server.core.ws_clients)
            now_t = time()
            if (now_t - last_sweep) >= 5.0  # sweep every 5s
                _wsidlesweep!(server)
                last_sweep = now_t
            end
        end
        yield()
    end
end
