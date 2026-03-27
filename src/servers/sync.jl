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
    c_handler = Mongoose.c_handler_sync(typeof(router))
    core = ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms, c_handler=c_handler)
    server = SyncServer{typeof(router)}(core)
    finalizer(free_resources!, server)
    return server
end

function setup_resources!(server::SyncServer)
    server.core.manager = Manager()
    return
end

function run_event_loop(server::SyncServer)
    server.core.running[] = true
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        yield()
    end
end
