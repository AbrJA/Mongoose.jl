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
    # --- 1. Execution State ---
    running::Threads.Atomic{Bool}
    server_task::Union{Nothing, Task}
    manager::Manager
    handler::Ptr{Cvoid}             # C-interop handler
    sockets::Dict{Int, String}
    next_id::Threads.Atomic{UInt64} # Connection/Request ID generator

    # --- 2. Routing & Logic ---
    router::R
    pipeline::Vector{AbstractMiddleware}
    mounts::Vector{Tuple{String, String}}
    errors::Dict{Int, Response}

    # --- 3. Configuration & Limits ---
    poll_timeout::Int
    request_timeout::Int
    drain_timeout::Int
    max_body::Int

    # --- 4. UI/UX Preferences ---
    pretty::Bool

    # Inner Constructor
    function ServerCore(poll_timeout::Integer, router::R;
                        max_body::Integer = MAX_BODY,
                        drain_timeout::Integer = DRAIN_TIMEOUT,
                        request_timeout::Integer = 0,
                        errors::Dict{Int, Response} = Dict{Int, Response}(),
                        c_handler::Ptr{Cvoid} = C_NULL,
                        pretty::Bool = true) where {R <: AbstractRouter}

        return new{R}(
            Threads.Atomic{Bool}(false),    # running
            nothing,                        # server_task (formerly master)
            Manager(empty=true),            # manager
            c_handler,                      # handler
            Dict{Int, String}(),            # sockets
            Threads.Atomic{UInt64}(0),      # next_id (formerly id)
            router,                         # router
            AbstractMiddleware[],           # pipeline (formerly plugs)
            Tuple{String, String}[],        # mounts
            errors,                         # errors
            poll_timeout,                   # poll_timeout (formerly timeout)
            request_timeout,                # request_timeout
            drain_timeout,                  # drain_timeout
            max_body,                       # max_body
            pretty                          # pretty
        )
    end
end

# --- ServerConfig ---

"""
    ServerConfig

Consolidated configuration for `SyncServer` and `AsyncServer`. Pass a
`ServerConfig` as the second positional argument to either constructor instead
of individual keyword arguments.

# Fields

| Field | Default | Description |
|-------|---------|-------------|
| `timeout` | `1` | Event-loop poll timeout in ms. Use `0` for min latency (high CPU). |
| `max_body` | 1 MB | Maximum request body size in bytes. |
| `drain_timeout` | 5000 | Graceful-shutdown drain period in ms. |
| `request_timeout` | 0 | Per-request timeout in ms; `0` = disabled (AsyncServer only). |
| `workers` | 4 | Number of worker tasks (AsyncServer only). |
| `nqueue` | 1024 | Channel buffer size (AsyncServer only). |
| `errors` | `Dict()` | Custom `Response` objects keyed by HTTP status (`500`, `413`, `504`). |

# Example
```julia
config = ServerConfig(workers=8, request_timeout=15_000, max_body=5_242_880)

server = AsyncServer(router, config)
plug!(server, health())
start!(server; host="0.0.0.0", port=8080)
```

`ServerConfig` can be built from environment variables:
```julia
config = ServerConfig(
    workers           = parse(Int, get(ENV, "WORKERS", "4")),
    max_body     = parse(Int, get(ENV, "MAX_BODY",  "1048576")),
    request_timeout = parse(Int, get(ENV, "REQ_TIMEOUT", "0")),
)
```
"""
Base.@kwdef struct ServerConfig
    timeout::Int            = 1
    max_body::Int      = MAX_BODY
    drain_timeout::Int   = DRAIN_TIMEOUT
    request_timeout::Int = 0
    workers::Int            = 4
    nqueue::Int             = 1024
    errors::Dict{Int,Response} = Dict{Int,Response}()
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
    return url
end

function _spawnloop!(server::AbstractServer)
    server.core.master = Threads.@spawn begin
        try
            _eventloop(server)
        catch e
            if !isa(e, InterruptException)
                @error "Server event loop error" component="eventloop" exception=(e, catch_backtrace())
            end
        finally
            server.core.running[] = false
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
