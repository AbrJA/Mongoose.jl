"""
    Core server types — shared state, configuration, and abstract server definitions.
"""

# --- RAII Manager for C library lifecycle ---

"""
    Manager — RAII wrapper around the Mongoose C `mg_mgr` struct.
    Automatically allocates/frees memory via `calloc`/`free`.
"""
mutable struct Manager
    ptr::Ptr{Cvoid}
    function Manager(; empty::Bool=false)
        empty && return new(C_NULL)
        ptr = Libc.calloc(1, Csize_t(MG_MGR_SIZE))
        ptr == C_NULL && throw(ServerError("Failed to allocate manager memory"))
        mg_log_set_level(MG_LL_NONE)
        mg_mgr_init!(ptr)
        return new(ptr)
    end
end

function free!(manager::Manager)
    if manager.ptr != C_NULL
        mg_mgr_free!(manager.ptr)
        Libc.free(manager.ptr)
        manager.ptr = C_NULL
    end
end

# --- TLS Configuration ---

"""
    TLSConfig — TLS options for HTTPS servers.

    `cert`, `key`, and `ca` accept: file paths, PEM strings, or raw bytes.
"""
Base.@kwdef struct TLSConfig
    cert::Union{String,Vector{UInt8}} = ""
    key::Union{String,Vector{UInt8}} = ""
    ca::Union{String,Vector{UInt8}} = ""
    name::String = ""
    skip_verification::Bool = false
end

# --- Validation (defined early for use in ServerCore constructor) ---

function validate_core!(poll_timeout, max_body, drain_timeout, request_timeout, ws_max_frame, ws_idle_timeout)
    max_body > 0 || throw(ServerError("max_body must be > 0"))
    poll_timeout >= 0 || throw(ServerError("poll_timeout must be >= 0"))
    drain_timeout >= 0 || throw(ServerError("drain_timeout must be >= 0"))
    request_timeout >= 0 || throw(ServerError("request_timeout must be >= 0"))
    ws_max_frame > 0 || throw(ServerError("ws_max_frame must be > 0"))
    ws_idle_timeout >= 0 || throw(ServerError("ws_idle_timeout must be >= 0"))
end

function validate_errors!(errors::Dict{Int,Response})
    for code in keys(errors)
        (100 <= code <= 599) || throw(ServerError("Error status code must be in [100,599], got $code"))
    end
end

# --- Server Core (shared state, parametric on router type) ---

"""
    ServerCore{R} — Shared mutable state for all server variants.
    Parametric on router type R for specialization.
"""
mutable struct ServerCore{R<:AbstractRouter}
    running::Threads.Atomic{Bool}
    master::Union{Nothing,Task}
    manager::Manager
    c_handler::Ptr{Cvoid}
    tls::Union{Nothing,TLSConfig}
    ws_clients::Dict{Int,WsConn}
    id_seq::Threads.Atomic{UInt64}

    router::R
    middlewares::Vector{AbstractMiddleware}
    mounts::Vector{Tuple{String,String}}
    errors::Dict{Int,Response}
    services::Union{Nothing,ServiceRegistry}

    poll_timeout::Int
    request_timeout::Int
    drain_timeout::Int
    max_body::Int
    ws_max_frame::Int
    ws_idle_timeout::Int

    function ServerCore(router::R;
                        poll_timeout::Integer=1,
                        max_body::Integer=MAX_BODY,
                        drain_timeout::Integer=DRAIN_TIMEOUT,
                        request_timeout::Integer=0,
                        ws_max_frame::Integer=MAX_BODY,
                        ws_idle_timeout::Integer=0,
                        errors::Dict{Int,Response}=Dict{Int,Response}(),
                        services::Union{Nothing,ServiceRegistry}=nothing,
                        c_handler::Ptr{Cvoid}=C_NULL) where {R<:AbstractRouter}
        validate_core!(poll_timeout, max_body, drain_timeout, request_timeout, ws_max_frame, ws_idle_timeout)
        validate_errors!(errors)
        return new{R}(
            Threads.Atomic{Bool}(false),
            nothing,
            Manager(empty=true),
            c_handler,
            nothing,
            Dict{Int,WsConn}(),
            Threads.Atomic{UInt64}(0),
            router,
            AbstractMiddleware[],
            Tuple{String,String}[],
            errors,
            services,
            Int(poll_timeout),
            Int(request_timeout),
            Int(drain_timeout),
            Int(max_body),
            Int(ws_max_frame),
            Int(ws_idle_timeout)
        )
    end
end

# --- Configuration ---

"""
    Config — Consolidated configuration for `Server` and `Async`.

    Pass as the second argument to either constructor:
    ```julia
    config = Config(nworkers=8, request_timeout=15_000)
    server = Async(router, config)
    ```
"""
Base.@kwdef struct Config
    poll_timeout::Int       = 1
    max_body::Int           = MAX_BODY
    drain_timeout::Int      = DRAIN_TIMEOUT
    request_timeout::Int    = 0
    ws_max_frame::Int       = MAX_BODY
    ws_idle_timeout::Int    = 0
    nworkers::Int           = 4
    nqueue::Int             = 1024
    errors::Dict{Int,Response} = Dict{Int,Response}()
end

# --- Validation ---

function validate_config!(config::Config)
    config.nworkers > 0 || throw(ServerError("nworkers must be > 0, got $(config.nworkers)"))
    config.nqueue > 0 || throw(ServerError("nqueue must be > 0, got $(config.nqueue)"))
end

# --- Server Types ---

"""
    Server{R} — Single-threaded blocking server. AOT-compatible.
"""
mutable struct Server{R<:AbstractRouter} <: AbstractServer
    core::ServerCore{R}
end

"""
    Async{R} — Multi-threaded server with worker pool.
"""
mutable struct Async{R<:AbstractRouter} <: AbstractServer
    core::ServerCore{R}
    workers::Vector{Task}
    calls::Channel{Call}
    replies::Channel{Reply}
    connections::Dict{Int,MgConnection}
    nworkers::Int
    nqueue::Int
    inflight::Threads.Atomic{Int}
end

# --- C function pointer generation ---

cfunc_async(::Type{T}) where {T} = C_NULL
cfunc_sync(::Type{T}) where {T} = C_NULL

# --- Property forwarding (cleaner external API) ---

const _CORE_FIELDS = (:router, :middlewares, :mounts, :errors, :services,
                       :running, :manager, :tls, :ws_clients, :id_seq,
                       :poll_timeout, :request_timeout, :drain_timeout,
                       :max_body, :ws_max_frame, :ws_idle_timeout)

function Base.getproperty(s::AbstractServer, name::Symbol)
    name === :core && return getfield(s, :core)
    name in _CORE_FIELDS && return getfield(getfield(s, :core), name)
    return getfield(s, name)
end

function Base.setproperty!(s::AbstractServer, name::Symbol, value)
    name === :core && return setfield!(s, :core, value)
    name in _CORE_FIELDS && return setfield!(getfield(s, :core), name, value)
    return setfield!(s, name, value)
end

# --- Teardown ---

function teardown!(server::AbstractServer)
    free!(server.core.manager)
end
