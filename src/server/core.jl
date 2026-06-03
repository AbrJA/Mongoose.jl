"""
    Core server types — App, configuration constants, and lifecycle hooks.
"""

# --- RAII Manager for C library lifecycle ---

"""
    Manager — RAII wrapper around the Mongoose C `mg_mgr` struct.
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
    TLSConfig — TLS options for HTTPS/WSS servers.

    `cert`, `key`, and `ca` accept: file paths, PEM strings, or raw bytes.
"""
Base.@kwdef struct TLSConfig
    cert::Union{String,Vector{UInt8}} = ""
    key::Union{String,Vector{UInt8}} = ""
    ca::Union{String,Vector{UInt8}} = ""
    name::String = ""
    skip_verification::Bool = false
end

# --- App — unified server type ---

"""
    App — Mongoose.jl web application.

    Replaces the former `Server{R}` / `Async{R}` split.
    Use `workers=0` for sync (default) or `workers=N` for async worker pool.

    # Constructors
    ```julia
    app = App()                          # sync, dynamic router
    app = App(workers=4)                 # async, 4 workers
    app = App(workers=4, queuesize=2048) # async with larger queue
    app = App(router=my_router)          # bring-your-own router
    ```

    # Configuration keyword arguments
    | Keyword         | Default        | Description                                  |
    |-----------------|----------------|----------------------------------------------|
    | `workers`       | `0`            | Worker threads (0 = sync)                    |
    | `queuesize`     | `1024`         | Max pending requests (async only)            |
    | `poll_timeout`  | `1`            | Mongoose poll interval (ms)                  |
    | `max_body`      | `MAX_BODY`     | Max request body size (bytes)                |
    | `drain_timeout` | `DRAIN_TIMEOUT`| Graceful shutdown drain (ms)                 |
    | `request_timeout`| `0`           | Per-request timeout ms (0 = disabled)        |
    | `ws_max_frame`  | `MAX_BODY`     | Max WebSocket frame size (bytes)             |
    | `ws_idle_timeout`| `0`           | WS idle timeout ms (0 = disabled)            |
    | `router`        | `Router()`     | Custom router instance                       |
    | `tls`           | `nothing`      | `TLSConfig` for HTTPS                        |
"""
mutable struct App <: AbstractServer
    # C / manager state
    running::Threads.Atomic{Bool}
    master::Union{Nothing,Task}
    manager::Manager
    c_handler::Ptr{Cvoid}
    tls::Union{Nothing,TLSConfig}

    # Connection tracking
    ws_clients::Dict{Int,WsConn}
    id_seq::Threads.Atomic{UInt64}

    # Routing & middleware
    router::Router
    middlewares::Vector{AbstractMiddleware}
    mounts::Vector{Tuple{String,String}}

    # Error handling & DI
    errors::Dict{Int,Union{Response,Function}}
    services::Dict{Symbol,Any}

    # Lifecycle hooks
    hooks_start::Vector{Function}
    hooks_stop::Vector{Function}
    bg_tasks::Vector{Task}   # background tasks (spawned at start!)

    # Tuning
    poll_timeout::Int
    max_body::Int
    drain_timeout::Int
    request_timeout::Int
    ws_max_frame::Int
    ws_idle_timeout::Int

    # Async worker pool (workers=0 → sync mode)
    workers::Int
    queuesize::Int
    worker_tasks::Vector{Task}
    calls::Channel{Tagged{Union{Request,Intent}}}
    replies::Channel{Tagged{Union{Response,StreamResponse,Message}}}
    connections::Dict{Int,MgConnection}
    inflight::Threads.Atomic{Int}

    function App(;
                 workers::Integer=0,
                 queuesize::Integer=1024,
                 poll_timeout::Integer=1,
                 max_body::Integer=MAX_BODY,
                 drain_timeout::Integer=DRAIN_TIMEOUT,
                 request_timeout::Integer=0,
                 ws_max_frame::Integer=MAX_BODY,
                 ws_idle_timeout::Integer=0,
                 router::Router=Router(),
                 tls::Union{Nothing,TLSConfig}=nothing,
                 errors::Dict{Int,<:Any}=Dict{Int,Union{Response,Function}}(),
                 services::Dict{Symbol,<:Any}=Dict{Symbol,Any}())
        max_body > 0 || throw(ServerError("max_body must be > 0"))
        poll_timeout >= 0 || throw(ServerError("poll_timeout must be >= 0"))
        drain_timeout >= 0 || throw(ServerError("drain_timeout must be >= 0"))
        ws_max_frame > 0 || throw(ServerError("ws_max_frame must be > 0"))
        workers >= 0 || throw(ServerError("workers must be >= 0"))
        workers > 0 && queuesize > 0 || workers == 0 ||
            throw(ServerError("queuesize must be > 0 when workers > 0"))

        errs = Dict{Int,Union{Response,Function}}(k => v for (k, v) in errors)
        for code in keys(errs)
            (100 <= code <= 599) || throw(ServerError("Error status code must be in [100,599], got $code"))
        end

        ch_size = workers > 0 ? queuesize : 0
        return new(
            Threads.Atomic{Bool}(false),
            nothing,
            Manager(empty=true),
            C_NULL,
            tls,
            Dict{Int,WsConn}(),
            Threads.Atomic{UInt64}(0),
            router,
            AbstractMiddleware[],
            Tuple{String,String}[],
            errs,
            Dict{Symbol,Any}(services),
            Function[],
            Function[],
            Task[],
            Int(poll_timeout),
            Int(max_body),
            Int(drain_timeout),
            Int(request_timeout),
            Int(ws_max_frame),
            Int(ws_idle_timeout),
            Int(workers),
            Int(queuesize),
            Task[],
            Channel{Tagged{Union{Request,Intent}}}(ch_size),
            Channel{Tagged{Union{Response,StreamResponse,Message}}}(ch_size),
            Dict{Int,MgConnection}(),
            Threads.Atomic{Int}(0)
        )
    end
end

# --- Teardown ---

function teardown!(app::App)
    free!(app.manager)
end

# --- Registration helpers ---

"""
    onerror!(app, status, handler)

Register a custom error handler for a specific HTTP status code.
`handler` may be a `Response` (static) or `Function(req, status) → Response` (dynamic).

# Example
```julia
onerror!(app, 404) do req, status
    json(Dict("error" => "not found", "path" => req.uri); status=404)
end
```
"""
function onerror!(app::App, status::Int, handler::Union{Response,Function})
    (100 <= status <= 599) || throw(ServerError("Status code must be in [100,599]"))
    app.errors[status] = handler
    return app
end
onerror!(f::Function, app::App, status::Int) = onerror!(app, status, f)

"""
    onstart!(app, f)

Register a callback to run after the server starts (before accepting connections).
"""
function onstart!(f::Function, app::App)
    push!(app.hooks_start, f)
    return app
end

"""
    onstop!(app, f)

Register a callback to run during graceful shutdown.
"""
function onstop!(f::Function, app::App)
    push!(app.hooks_stop, f)
    return app
end

"""
    service!(app, name, value)

Register a service for dependency injection.

```julia
service!(app, :db, MyDB.connect())
service(req, :db)   # retrieve inside handler
```
"""
function service!(app::App, name::Symbol, value)
    app.services[name] = value
    return app
end

"""
    service(req, name) → Any

Retrieve a service by name from the request context.
"""
function service(req::Request, name::Symbol)
    ctx = req.context
    if ctx !== nothing
        app = get(ctx, :_app, nothing)
        if app isa App
            v = get(app.services, name, nothing)
            return v isa Function ? v() : v
        end
    end
    return nothing
end

"""
    background!(app, f)

Schedule a background task to be spawned when `start!` is called.
`f` should be a zero-argument function.

```julia
background!(app) do
    while true
        cleanup_expired_sessions!()
        sleep(60)
    end
end
```
"""
function background!(f::Function, app::App)
    push!(app.hooks_start, () -> push!(app.bg_tasks, @async f()))
    return app
end

# --- Display ---

function Base.show(io::IO, app::App)
    mode = app.workers == 0 ? "sync" : "async($(app.workers) workers)"
    routes = route_count(app.router)
    print(io, "App($mode, $routes routes, $(length(app.middlewares)) middleware)")
end
