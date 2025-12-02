const REGISTRY = Dict{UInt,Server}()

function register!(server::Server)
    get!(REGISTRY, objectid(server), server)
    return
end

function unregister!(server::Server)
    delete!(REGISTRY, objectid(server))
    return
end

function shutdown_all!()
    for server in collect(values(REGISTRY))
        shutdown!(server)
    end
    return
end
