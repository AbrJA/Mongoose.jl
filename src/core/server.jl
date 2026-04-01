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
    static_dirs::Vector{Tuple{String,String}}  # [(dir, uri_prefix), ...] for C-level static file serving
    request_timeout_ms::Int                      # Per-request timeout (0 = disabled)
    error_responses::Dict{Int,Response}   # Custom responses keyed by HTTP status code
    request_id::Threads.Atomic{UInt64}    # Monotonic request ID counter

    function ServerCore(timeout::Integer, router::R;
                        max_body_size::Integer=DEFAULT_MAX_BODY_SIZE,
                        drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS,
                        request_timeout_ms::Integer=0,
                        error_responses::Dict{Int,Response}=Dict{Int,Response}(),
                        c_handler::Ptr{Cvoid}=C_NULL) where {R <: AbstractRouter}
        return new{R}(
            Manager(empty=true), c_handler, timeout, nothing,
            router, Dict{Int,String}(),
            Threads.Atomic{Bool}(false), AbstractMiddleware[],
            max_body_size, drain_timeout_ms, Tuple{String,String}[],
            request_timeout_ms, error_responses, Threads.Atomic{UInt64}(0)
        )
    end
end

# Default error responses returned when no custom entry is in error_responses
const _DEFAULT_500 = Response(500, ContentType.text, "500 Internal Server Error")
const _DEFAULT_413 = Response(413, ContentType.text, "413 Payload Too Large")
const _DEFAULT_504 = Response(504, ContentType.text, "504 Gateway Timeout")

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
| `max_body_size` | 1 MB | Maximum request body size in bytes. |
| `drain_timeout_ms` | 5000 | Graceful-shutdown drain period in ms. |
| `request_timeout_ms` | 0 | Per-request timeout in ms; `0` = disabled (AsyncServer only). |
| `workers` | 4 | Number of worker tasks (AsyncServer only). |
| `nqueue` | 1024 | Channel buffer size (AsyncServer only). |
| `error_responses` | `Dict()` | Custom `Response` objects keyed by HTTP status (`500`, `413`, `504`). |

# Example
```julia
config = ServerConfig(workers=8, request_timeout_ms=15_000, max_body_size=5_242_880)

server = AsyncServer(router, config)
use!(server, health())
start!(server; host="0.0.0.0", port=8080)
```

`ServerConfig` can be built from environment variables:
```julia
config = ServerConfig(
    workers           = parse(Int, get(ENV, "WORKERS", "4")),
    max_body_size     = parse(Int, get(ENV, "MAX_BODY",  "1048576")),
    request_timeout_ms = parse(Int, get(ENV, "REQ_TIMEOUT_MS", "0")),
)
```
"""
Base.@kwdef struct ServerConfig
    timeout::Int            = 1
    max_body_size::Int      = DEFAULT_MAX_BODY_SIZE
    drain_timeout_ms::Int   = DEFAULT_DRAIN_TIMEOUT_MS
    request_timeout_ms::Int = 0
    workers::Int            = 4
    nqueue::Int             = 1024
    error_responses::Dict{Int,Response} = Dict{Int,Response}()
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
