"""
    Core server structs and lifecycle primitives.
"""

"""
    Manager — RAII wrapper around the Mongoose C `mg_mgr` struct.
"""
mutable struct Manager
    ptr::Ptr{Cvoid}
    function Manager(; empty::Bool=false)
        empty && return new(C_NULL)
        ptr = Libc.calloc(1, Csize_t(MG_MGR_SIZE))
        ptr == C_NULL && throw(ServerError("Failed to allocate manager memory"))
        mg_log_set_level(MG_LL_NONE) # Set level before initializing
        mg_mgr_init!(ptr)
        return new(ptr)
    end
end

"""
    free!(manager) — Free the Mongoose manager and its allocated memory.
"""
function free!(manager::Manager)
    if manager.ptr != C_NULL
        mg_mgr_free!(manager.ptr)
        Libc.free(manager.ptr)
        manager.ptr = C_NULL
    end
    return
end

"""
    ServerCore{R} — Shared state. R <: AbstractRouter
"""
mutable struct ServerCore{R <: AbstractRouter}
    manager::Manager
    handler::Ptr{Cvoid}
    timeout::Int
    master::Union{Nothing,Task}
    router::R
    ws_connections::Dict{Int,String}
    running::Threads.Atomic{Bool}
    middlewares::Vector{AbstractMiddleware}
    max_body_size::Int
    drain_timeout_ms::Int

    function ServerCore(timeout::Integer, router::R;
                        max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                        drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS,
                        c_handler::Ptr{Cvoid}=C_NULL) where {R <: AbstractRouter}
        return new{R}(
            Manager(empty=true), c_handler, timeout, nothing,
            router, Dict{Int,String}(),
            Threads.Atomic{Bool}(false), AbstractMiddleware[],
            max_body_size, drain_timeout_ms
        )
    end
end

# --- Abstract Server Implementations (Structs only) ---

"""
    SyncServer — Single-threaded blocking server.
"""
mutable struct SyncServer{R <: AbstractRouter} <: AbstractServer
    core::ServerCore{R}
end

"""
    AsyncServer — Multi-threaded server using worker tasks.
"""
mutable struct AsyncServer{R <: AbstractRouter} <: AbstractServer
    core::ServerCore{R}
    workers::Vector{Task}
    calls::Channel{Call}
    replies::Channel{Reply}
    connections::Dict{Int,MgConnection}
    nworkers::Int
    nqueue::Int
end

# --- Shared Lifecycle Primitives ---

_cfnasync(::Type{T}) where {T} = C_NULL
_cfnsync(::Type{T}) where {T} = C_NULL

function _teardown!(server::AbstractServer)
    free!(server.core.manager)
    return
end

function _bind!(server::AbstractServer, host::AbstractString, port::Integer)
    url = "http://$host:$port"
    fn_data = pointer_from_objref(server)
    is_listen = mg_http_listen(server.core.manager.ptr, url, server.core.handler, fn_data)
    is_listen == C_NULL && throw(BindError("Failed to start server on $url. Port may be in use."))
    @info "Listening on $url"
    return
end

function _spawnloop!(server::AbstractServer)
    server.core.master = Threads.@spawn begin
        try
            _eventloop(server)
        catch e
            if !isa(e, InterruptException)
                @error "Server event loop error: $e" exception = (e, catch_backtrace())
            end
        finally
            server.core.running[] = false
            @info "Server event loop task finished."
        end
    end
    return
end

function _stoploop!(server::AbstractServer)
    if !isnothing(server.core.master)
        try wait(server.core.master) catch end
        server.core.master = nothing
    end
    return
end
