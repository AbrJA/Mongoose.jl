"""
    SyncServer — Single-threaded blocking server methods.
"""

"""
    SyncServer(router=Router(); timeout=0, max_body_size, drain_timeout_ms)

Create a single-threaded blocking server. Compatible with `juliac --trim=safe`.
"""
SyncServer(::Type{T}; kwargs...) where {T <: StaticRouter} = SyncServer(T(); kwargs...)

function SyncServer(router::AbstractRouter=Router();
                    timeout::Integer=0,
                    max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                    drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS)
    c_handler = Mongoose._cfnsync(typeof(router))
    core = ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=c_handler)
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
