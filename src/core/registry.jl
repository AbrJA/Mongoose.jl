"""
    Global server registry — maps `objectid(server)` to server instances.
    Protected by `REGISTRY_LOCK`. Only mutated during `start!`/`shutdown!`.
    Keeps servers rooted while C holds a `pointer_from_objref` reference to them.
"""

const REGISTRY_LOCK = ReentrantLock()
const REGISTRY = Dict{UInt,AbstractServer}()

"""
    _register!(server) — Add a server to the global registry.
    The registry key is `objectid(server)`. During `_bind!`, the server's
    raw object pointer (`pointer_from_objref(server)`) is passed as `fn_data`
    to the C listener, and recovered in the C callback via
    `unsafe_pointer_to_objref(fn_data)`. The registry keeps the server rooted
    (preventing GC collection) for the lifetime of the listener.
"""
function _register!(server::AbstractServer)
    lock(REGISTRY_LOCK) do
        get!(REGISTRY, objectid(server), server)
    end
    return
end

"""
    _unregister!(server) — Remove a server from the global registry.
"""
function _unregister!(server::AbstractServer)
    lock(REGISTRY_LOCK) do
        delete!(REGISTRY, objectid(server))
    end
    return
end

"""
    shutdown!() — Stop all running servers.
    Collects servers first to avoid mutating the registry during iteration.
"""
function shutdown!()
    servers = lock(REGISTRY_LOCK) do
        collect(values(REGISTRY))
    end
    for server in servers
        shutdown!(server)
    end
    return
end
