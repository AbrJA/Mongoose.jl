"""
    Global server registry — maps `objectid(server)` to server instances.

    Protected by SpinLock (never yields — safe inside C callback frames).
    Only mutated during start!/shutdown!.

    GC-safe design: `fn_data` passed to C stores `objectid(server)` as UInt64,
    NOT a raw heap address. Recovery via Dict lookup eliminates GC race conditions.
"""

const REGISTRY_LOCK = Threads.SpinLock()
const REGISTRY = Dict{UInt,AbstractServer}()

"""
    register_server!(server)

Add a server to the global registry. Key is `objectid(server)`.
"""
function register_server!(server::AbstractServer)
    lock(REGISTRY_LOCK) do
        get!(REGISTRY, objectid(server), server)
    end
end

"""
    unregister_server!(server)

Remove a server from the global registry.
"""
function unregister_server!(server::AbstractServer)
    lock(REGISTRY_LOCK) do
        delete!(REGISTRY, objectid(server))
    end
end

"""
    lookup_server(oid) → Union{Nothing, AbstractServer}

Recover a server by its objectid token. Called from C callbacks.
Uses explicit lock/unlock (no closure) to avoid allocation on hot path.
"""
@inline function lookup_server(oid::UInt)::Union{Nothing,AbstractServer}
    lock(REGISTRY_LOCK)
    server = get(REGISTRY, oid, nothing)
    unlock(REGISTRY_LOCK)
    return server
end

# --- Process-exit shutdown ---
# Julia blocks SIGTERM and handles it in its runtime, which runs `atexit`
# callbacks before terminating; SIGINT is delivered as an exception. A custom
# C signal handler cannot intercept SIGTERM (the signal is blocked process-
# wide), so graceful shutdown on SIGTERM/exit goes through this `atexit` hook.

# Best-effort graceful shutdown of every registered server at process exit.
function _shutdown_registered!()
    servers = lock(REGISTRY_LOCK) do
        collect(values(REGISTRY))
    end
    for s in servers
        try
            shutdown!(s)
        catch e
            @log_error "atexit shutdown error" e catch_backtrace()
        end
    end
    return nothing
end
