"""
    Server{R} — Single-threaded blocking server.

    Handles all requests on the event loop thread. Compatible with juliac --trim=safe.
"""

Server(::Type{T}; kwargs...) where {T<:StaticRouter} = Server(T(); kwargs...)
Server(::Type{T}, config::Config) where {T<:StaticRouter} = Server(T(), config)

function Server(router::AbstractRouter=Router();
                poll_timeout::Integer=1,
                max_body::Integer=MAX_BODY,
                drain_timeout::Integer=DRAIN_TIMEOUT,
                ws_max_frame::Integer=MAX_BODY,
                ws_idle_timeout::Integer=0,
                errors::Dict{Int,Response}=Dict{Int,Response}(),
                services::Union{Nothing,ServiceRegistry}=nothing)
    c_handler = cfunc_sync(typeof(router))
    core = ServerCore(router; poll_timeout=poll_timeout, max_body=max_body,
                      drain_timeout=drain_timeout, ws_max_frame=ws_max_frame,
                      ws_idle_timeout=ws_idle_timeout, errors=errors,
                      services=services, c_handler=c_handler)
    server = Server{typeof(router)}(core)
    finalizer(teardown!, server)
    return server
end

function Server(router::AbstractRouter, config::Config;
                services::Union{Nothing,ServiceRegistry}=nothing)
    validate_config!(config)
    config.request_timeout > 0 && @log_warn "request_timeout ignored by Server (use Async)"
    return Server(router; poll_timeout=config.poll_timeout, max_body=config.max_body,
                  drain_timeout=config.drain_timeout, ws_max_frame=config.ws_max_frame,
                  ws_idle_timeout=config.ws_idle_timeout, errors=copy(config.errors),
                  services=services)
end

function init_server!(server::Server)
    server.core.manager = Manager()
    empty!(server.core.ws_clients)
end

function event_loop(server::Server)
    mgr = server.core.manager.ptr
    timeout = server.core.poll_timeout
    last_sweep = time()
    while server.core.running[]
        mg_mgr_poll(mgr, timeout)
        # Flush WS send buffers
        isempty(server.core.ws_clients) || mg_mgr_poll(mgr, 0)
        # Periodic idle sweep
        if server.core.ws_idle_timeout > 0 && !isempty(server.core.ws_clients)
            now = time()
            if (now - last_sweep) >= 5.0
                ws_idle_sweep!(server)
                last_sweep = now
            end
        end
        yield()
    end
end
