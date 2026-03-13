const REGISTRY_LOCK = ReentrantLock()
const REGISTRY = Dict{UInt,Server}()

function register!(server::Server)
    lock(REGISTRY_LOCK) do
        get!(REGISTRY, objectid(server), server)
    end
    return
end

function unregister!(server::Server)
    lock(REGISTRY_LOCK) do
        delete!(REGISTRY, objectid(server))
    end
    return
end

"""
shutdown!()
    Stops all running servers.
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
