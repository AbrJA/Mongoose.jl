"""
    Global server registry — maps `objectid(server)` to server instances.
    Protected by REGISTRY_LOCK (SpinLock, never yields — safe inside @cfunction
    callbacks from C). Only mutated during `start!`/`shutdown!`.

    GC-safe C callback design: `fn_data` passed to the C library stores
    `objectid(server)` cast to a `Ptr{Cvoid}` — a stable UInt64 identity
    token, NOT a raw heap address. The callback recovers the server by looking
    up this token in the REGISTRY, which is a normal Julia Dict reference that
    the GC fully understands. This eliminates the concurrent-GC race that
    `unsafe_pointer_to_objref` creates when the GC's marking phase writes to
    object headers while the callback reads them.
"""

const REGISTRY_LOCK = Threads.SpinLock()
const REGISTRY = Dict{UInt,AbstractServer}()

"""
    _register!(server) — Add a server to the global registry.

    The key is `objectid(server)`. During `_bind!`, this key is cast to
    `Ptr{Cvoid}` and passed as `fn_data` to `mg_http_listen`. The C callback
    recovers the server via `_lookupserver(UInt(fn_data))` — a safe Dict
    lookup rather than `unsafe_pointer_to_objref`.
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
    _lookupserver(oid) → AbstractServer or nothing

Recover a server from the global registry by its `objectid` token.
Called from C callbacks where `fn_data` stores the token.
Returns `nothing` if the server has already been unregistered (shutting down).
Uses explicit lock/unlock (no `do` closure) to avoid allocation on the hot path.
"""
function _lookupserver(oid::UInt)::Union{AbstractServer,Nothing}
    lock(REGISTRY_LOCK)
    try
        return get(REGISTRY, oid, nothing)
    finally
        unlock(REGISTRY_LOCK)
    end
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
