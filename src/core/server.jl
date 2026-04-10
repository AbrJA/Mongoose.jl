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
    running::Threads.Atomic{Bool}
    master::Union{Nothing, Task}
    manager::Manager
    c_handler::Ptr{Cvoid}
    ws_clients::Dict{Int, WsConn}
    id_seq::Threads.Atomic{UInt64}

    router::R
    middlewares::Vector{AbstractMiddleware}
    mounts::Vector{Tuple{String, String}}
    errors::Dict{Int, Response}

    poll_timeout::Int
    request_timeout::Int
    drain_timeout::Int
    max_body::Int
    ws_idle_timeout::Int

    styled::Bool

    function ServerCore(poll_timeout::Integer, router::R;
                        max_body::Integer = MAX_BODY,
                        drain_timeout::Integer = DRAIN_TIMEOUT,
                        request_timeout::Integer = 0,
                        ws_idle_timeout::Integer = 0,
                        errors::Dict{Int, Response} = Dict{Int, Response}(),
                        c_handler::Ptr{Cvoid} = C_NULL,
                        styled::Bool = isa(stdout, Base.TTY)) where {R <: AbstractRouter}

        return new{R}(
            Threads.Atomic{Bool}(false),
            nothing,
            Manager(empty=true),
            c_handler,
            Dict{Int, WsConn}(),
            Threads.Atomic{UInt64}(0),
            router,
            AbstractMiddleware[],
            Tuple{String, String}[],
            errors,
            poll_timeout,
            request_timeout,
            drain_timeout,
            max_body,
            ws_idle_timeout,
            styled
        )
    end
end

"""
    Config

Consolidated configuration for `Server` and `Async`. Pass a
`Config` as the second positional argument to either constructor instead
of individual keyword arguments.

# Fields

| Field | Default | Description |
|-------|---------|-------------|
| `poll_timeout` | `1` | Event-loop poll timeout in ms. Use `0` for min latency (high CPU). |
| `max_body` | 1 MB | Maximum request body size in bytes. |
| `drain_timeout` | 5000 | Graceful-shutdown drain period in ms. |
| `request_timeout` | 0 | Per-request timeout in ms; `0` = disabled (Async only). |
| `nworkers` | 4 | Number of worker tasks (Async only). |
| `nqueue` | 1024 | Channel buffer size (Async only). |
| `errors` | `Dict()` | Custom `Response` objects keyed by HTTP status (`500`, `413`, `504`). |

# Example
```julia
config = Config(nworkers=8, request_timeout=15_000, max_body=5_242_880)

server = Async(router, config)
plug!(server, health())
start!(server; host="0.0.0.0", port=8080)
```

`Config` can be built from environment variables:
```julia
config = Config(
    nworkers          = parse(Int, get(ENV, "WORKERS", "4")),
    max_body     = parse(Int, get(ENV, "MAX_BODY",  "1048576")),
    request_timeout = parse(Int, get(ENV, "REQ_TIMEOUT", "0")),
)
```
"""
Base.@kwdef struct Config
    poll_timeout::Int            = 1
    max_body::Int      = MAX_BODY
    drain_timeout::Int   = DRAIN_TIMEOUT
    request_timeout::Int = 0
    ws_idle_timeout::Int = 0
    nworkers::Int           = 4
    nqueue::Int             = 1024
    errors::Dict{Int,Response} = Dict{Int,Response}()
    styled::Bool = isa(stdout, Base.TTY)
end

mutable struct Server{R <: AbstractRouter} <: AbstractServer
    core::ServerCore{R}
end

mutable struct Async{R <: AbstractRouter} <: AbstractServer
    core::ServerCore{R}
    workers::Vector{Task}
    calls::Channel{Call}
    replies::Channel{Reply}
    connections::Dict{Int,MgConnection}
    nworkers::Int
    nqueue::Int
end

_cfnasync(::Type{T}) where {T} = C_NULL
_cfnsync(::Type{T}) where {T} = C_NULL

function _teardown!(server::AbstractServer)
    free!(server.core.manager)
    return
end

function _bind!(server::AbstractServer, host::AbstractString, port::Integer)
    url = "http://$host:$port"
    fn_data = Ptr{Cvoid}(objectid(server))  # stable identity token, not heap address
    is_listen = mg_http_listen(server.core.manager.ptr, url, server.core.c_handler, fn_data)
    is_listen == C_NULL && throw(BindError("Failed to start server on $url. Port may be in use."))
    return url
end

function _spawnloop!(server::AbstractServer)
    server.core.master = @async begin
        try
            _eventloop(server)
        catch e
            if !isa(e, InterruptException)
                _log_error("Server event loop error component=eventloop", e, catch_backtrace())
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
