"""
    Global server registry — maps server `objectid` to server instances.
    Protected by `REGISTRY_LOCK`. Only mutated during `start!`/`shutdown!`.
"""

const REGISTRY_LOCK = ReentrantLock()
const REGISTRY = Dict{UInt,Server}()

"""
    register!(server) — Add a server to the global registry.
    The server's `objectid` is used as the key, which is passed as `fn_data`
    to the C event handler for server lookup during callbacks.
"""
function register!(server::Server)
    lock(REGISTRY_LOCK) do
        get!(REGISTRY, objectid(server), server)
    end
    return
end

"""
    unregister!(server) — Remove a server from the global registry.
"""
function unregister!(server::Server)
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
