const SERVER_REGISTRY = Dict{Int, Server}()

function register(server::Server)
    ptr = pointer_from_objref(server)
    id = Int(ptr)
    haskey(SERVER_REGISTRY, id) || (SERVER_REGISTRY[id] = server)
    return ptr
end

function deregister(server::Server)
    id = Int(pointer_from_objref(server))
    delete!(SERVER_REGISTRY, id)
    return
end

const SERVER = Ref{Server}()

function default_server()
    isassigned(SERVER) || (SERVER[] = Server())
    return SERVER[]
end
