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

# --- Dependency injection registry ---

"""
    ServiceRegistry — mutable container for typed NamedTuple services.

    `App(services=(db=pool, ...))` stores its services here; `service!` rebuilds
    the NamedTuple (a cold, pre-start operation). Handlers access services with
    `service(req, Val(:db))` for type-stable retrieval.
"""
mutable struct ServiceRegistry{T<:NamedTuple}
    deps::T
end
ServiceRegistry() = ServiceRegistry(NamedTuple())

# --- Active streaming responses (chunk channels drained by the event loop) ---

"""
    ActiveStream — one in-flight streaming response.

    The producer writes chunks to `channel` from a separate task; the event
    loop drains the channel on the poll thread (`drain_streams!`) and sends
    bytes via the C connection (which is not thread-safe).
"""
mutable struct ActiveStream
    channel::Channel{Union{Vector{UInt8},Nothing}}
    conn::MgConnection
    done::Bool
end

# --- ServerConfig — Immutable configuration separated from runtime state ---

"""
    ServerConfig — Immutable tuning parameters for the server.

    Separated from `App` runtime state to clearly distinguish what's
    configuration (set once) vs what changes during execution.
"""
struct ServerConfig
    poll_timeout::Int
    max_body::Int
    drain_timeout::Int
    request_timeout::Int
    ws_max_frame::Int
    ws_idle_timeout::Int
    workers::Int
    queuesize::Int

    function ServerConfig(;
                          poll_timeout::Integer=1,
                          max_body::Integer=MAX_BODY,
                          drain_timeout::Integer=DRAIN_TIMEOUT,
                          request_timeout::Integer=0,
                          ws_max_frame::Integer=MAX_BODY,
                          ws_idle_timeout::Integer=0,
                          workers::Integer=0,
                          queuesize::Integer=1024)
        max_body > 0 || throw(ServerError("max_body must be > 0"))
        poll_timeout >= 0 || throw(ServerError("poll_timeout must be >= 0"))
        drain_timeout >= 0 || throw(ServerError("drain_timeout must be >= 0"))
        ws_max_frame > 0 || throw(ServerError("ws_max_frame must be > 0"))
        workers >= 0 || throw(ServerError("workers must be >= 0"))
        workers > 0 && queuesize > 0 || workers == 0 ||
            throw(ServerError("queuesize must be > 0 when workers > 0"))
        new(Int(poll_timeout), Int(max_body), Int(drain_timeout),
            Int(request_timeout), Int(ws_max_frame), Int(ws_idle_timeout),
            Int(workers), Int(queuesize))
    end
end

# --- App — unified server type ---

"""
    App — Mongoose.jl web application.

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
mutable struct App{R<:AbstractRouter} <: AbstractServer
    # Immutable configuration
    const config::ServerConfig

    # C / manager state
    running::Threads.Atomic{Bool}
    master::Union{Nothing,Task}
    manager::Manager
    c_handler::Ptr{Cvoid}
    tls::Union{Nothing,TLSConfig}

    # Connection tracking
    ws_clients::Dict{Int,WsConn}
    id_seq::Threads.Atomic{UInt64}       # X-Request-Id sequence
    conn_seq::Threads.Atomic{UInt64}     # Async connection id sequence

    # Routing & middleware
    const router::R
    const middlewares::Vector{AbstractMiddleware}
    const mounts::Vector{Tuple{String,String}}

    # Error handling & DI
    const errors::Dict{Int,Union{Response,Function}}
    const exception_handlers::Dict{DataType,Function}
    services::ServiceRegistry

    # Lifecycle hooks
    const hooks_start::Vector{Function}
    const hooks_stop::Vector{Function}
    bg_tasks::Vector{Task}

    # Transport-side in-flight requests (async only): id → connection
    connections::Dict{Int,MgConnection}

    # Active streaming responses (chunk channels drained by the event loop)
    streams::Dict{Int,ActiveStream}

    # Execution strategy: SyncExecutor (inline) or AsyncExecutor (worker pool)
    const executor::AbstractExecutor

    function App(;
                 workers::Integer=0,
                 queuesize::Integer=1024,
                 poll_timeout::Integer=1,
                 max_body::Integer=MAX_BODY,
                 drain_timeout::Integer=DRAIN_TIMEOUT,
                 request_timeout::Integer=0,
                 ws_max_frame::Integer=MAX_BODY,
                 ws_idle_timeout::Integer=0,
                 router::R=Router(),
                 tls::Union{Nothing,TLSConfig}=nothing,
                 errors::Dict{Int,<:Any}=Dict{Int,Union{Response,Function}}(),
                 services::NamedTuple=NamedTuple()) where {R<:AbstractRouter}

        cfg = ServerConfig(;
            poll_timeout, max_body, drain_timeout, request_timeout,
            ws_max_frame, ws_idle_timeout, workers, queuesize)

        errs = Dict{Int,Union{Response,Function}}(k => v for (k, v) in errors)
        for code in keys(errs)
            (100 <= code <= 599) || throw(ServerError("Error status code must be in [100,599], got $code"))
        end

        exec = cfg.workers > 0 ? AsyncExecutor(cfg.workers, cfg.queuesize) : SyncExecutor()
        return new{R}(
            cfg,
            Threads.Atomic{Bool}(false),
            nothing,
            Manager(empty=true),
            C_NULL,
            tls,
            Dict{Int,WsConn}(),
            Threads.Atomic{UInt64}(0),
            Threads.Atomic{UInt64}(0),
            router,
            AbstractMiddleware[],
            Tuple{String,String}[],
            errs,
            Dict{DataType,Function}(),
            ServiceRegistry(services),
            Function[],
            Function[],
            Task[],
            Dict{Int,MgConnection}(),
            Dict{Int,ActiveStream}(),
            exec
        )
    end
end

# --- Config field accessors (backward-compatible) ---
@inline Base.getproperty(app::App, s::Symbol) = _app_getproperty(app, s, Val(s))
@inline _app_getproperty(app::App, ::Symbol, ::Val{S}) where {S} = getfield(app, S)
@inline _app_getproperty(app::App, ::Symbol, ::Val{:poll_timeout}) = getfield(app, :config).poll_timeout
@inline _app_getproperty(app::App, ::Symbol, ::Val{:max_body}) = getfield(app, :config).max_body
@inline _app_getproperty(app::App, ::Symbol, ::Val{:drain_timeout}) = getfield(app, :config).drain_timeout
@inline _app_getproperty(app::App, ::Symbol, ::Val{:request_timeout}) = getfield(app, :config).request_timeout
@inline _app_getproperty(app::App, ::Symbol, ::Val{:ws_max_frame}) = getfield(app, :config).ws_max_frame
@inline _app_getproperty(app::App, ::Symbol, ::Val{:ws_idle_timeout}) = getfield(app, :config).ws_idle_timeout
@inline _app_getproperty(app::App, ::Symbol, ::Val{:workers}) = getfield(app, :config).workers
@inline _app_getproperty(app::App, ::Symbol, ::Val{:queuesize}) = getfield(app, :config).queuesize

# --- Teardown ---

function teardown!(app::App)
    for st in values(app.streams)
        close(st.channel)
    end
    empty!(app.streams)
    free!(app.manager)
end

# --- Registration helpers ---

"""
    onerror!(app, status, handler)

Register a custom error handler for a specific HTTP status code.
`handler` may be a `Response` (static) or `Function(req) → Response` (dynamic).

# Example
```julia
onerror!(app, 404) do req
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
    onerror!(app, ::Type{E}, handler)

Register a typed exception handler: `handler(req, e)` returns the `Response`
for any handler/middleware error that is a `E` (or subtype). Handlers are
tried in registration order; unhandled exceptions fall through to the default
500 path.

# Example
```julia
struct NotFound <: Exception end
onerror!(app, NotFound) do req, e
    json(Dict("error" => "not found"); status=404)
end
```
"""
function onerror!(server::AbstractServer, ::Type{E}, handler::Function) where {E<:Exception}
    server.exception_handlers[E] = handler
    return server
end
onerror!(handler::Function, server::AbstractServer, ::Type{E}) where {E<:Exception} =
    onerror!(server, E, handler)

"""
    invoke_guarded(server, req, f)

Run `f()` and route any exception through `onerror!(::Type{E})` handlers. Falls
back to rethrowing so the default 500 path applies for unhandled types.
"""
function invoke_guarded(server::AbstractServer, req::Request, f::Function)
    isempty(server.exception_handlers) && return f()
    try
        return f()
    catch e
        for (T, handler) in server.exception_handlers
            e isa T && return handler(req, e)
        end
        rethrow(e)
    end
end

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
service(req, :db)      # retrieve inside handler
```
"""
function service!(app::App, name::Symbol, value)
    old = app.services.deps
    app.services = ServiceRegistry((; old..., name => value))
    return app
end

"""
    service(req, name) → Any
    service(req, ::Val{name}) → T
    service(req, name, T) → T

Retrieve a service by name from the request context.
- `service(req, :db)` returns the raw value (values may be zero-arg callables,
  which are invoked).
- `service(req, Val(:db))` is the **typed** form: with `services` registered as
  a NamedTuple, the return type is statically known.
- `service(req, :db, DBPool)` asserts the type and throws otherwise.

# Example
```julia
app = App(services=(db=pool, cache=redis))
db = service(req, Val(:db))        # type-stable: DBPool
```
"""
function service(req::Request, name::Symbol)
    ctx = req.context
    ctx === nothing && return nothing
    svcs = get(ctx, :_services, nothing)
    if svcs === nothing
        app = get(ctx, :_app, nothing)
        app isa App && (svcs = app.services.deps)
    end
    svcs isa NamedTuple || return nothing
    hasproperty(svcs, name) || return nothing
    v = getproperty(svcs, name)
    return v isa Function ? v() : v
end

@inline function service(req::Request, ::Val{name}) where {name}
    ctx = req.context
    ctx === nothing && return nothing
    svcs = get(ctx, :_services, nothing)
    if svcs === nothing
        app = get(ctx, :_app, nothing)
        app isa App && (svcs = app.services.deps)
    end
    svcs isa NamedTuple || return nothing
    hasproperty(svcs, name) || return nothing
    v = getfield(svcs, name)
    return v isa Function ? v() : v
end

function service(req::Request, name::Symbol, ::Type{T})::T where {T}
    v = service(req, name)
    v isa T && return v
    v === nothing && throw(KeyError(name))
    throw(TypeError(:service, T, v))
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

# --- use! (add middleware to an app) ---
# The middleware protocol (AbstractMiddleware, before/after) lives in
# MongooseCore; this server-layer method wires it onto an App.

"""
    use!(app, middleware; paths=[])

Add middleware to an app. `middleware` may be any callable
`(req, next) → Response` or an `AbstractMiddleware` subtype; plain functions
are wrapped automatically. When `paths` is non-empty, the middleware only
applies to requests whose URI starts with one of the given prefixes.

# Example
```julia
use!(app, cors())
use!(app, bearer(validate_token); paths=["/api"])
use!(app, (req, next) -> (req.headers ...; next()))
```
"""
function use!(server::AbstractServer, @nospecialize(mw); paths::Vector{String}=String[])
    inner = as_middleware(mw)
    wrapped = isempty(paths) ? inner : PathFilter(inner, paths)
    push!(server.middlewares, wrapped)
    return server
end

# Do-block convenience: use!(app) do req, next ... end
use!(f::Function, server::AbstractServer; paths::Vector{String}=String[]) =
    use!(server, f; paths=paths)
