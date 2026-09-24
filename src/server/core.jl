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

    `App(services=(db=pool, ...))` stores its services here; `service!` mutates
    `deps` in place (a cold, pre-start operation). Handlers access services with
    `service(req, Val(:db))` for convenient retrieval, or `withservices(req) do svcs … end` for type-stable access.
"""
mutable struct ServiceRegistry
    deps::NamedTuple
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
    poll_timeout_ms::Int
    max_body_bytes::Int
    drain_timeout_ms::Int
    request_timeout_ms::Int
    ws_max_frame_bytes::Int
    ws_idle_timeout_ms::Int
    header_timeout_ms::Int
    max_connections::Int
    workers::Int
    queue_size::Int

    function ServerConfig(;
                          poll_timeout_ms::Integer=1,
                          max_body_bytes::Integer=MAX_BODY_BYTES,
                          drain_timeout_ms::Integer=DRAIN_TIMEOUT_MS,
                          request_timeout_ms::Integer=0,
                          ws_max_frame_bytes::Integer=MAX_BODY_BYTES,
                          ws_idle_timeout_ms::Integer=0,
                          header_timeout_ms::Integer=0,
                          max_connections::Integer=0,
                          workers::Integer=0,
                          queue_size::Integer=1024)
        max_body_bytes > 0 || throw(ServerError("max_body_bytes must be > 0"))
        max_body_bytes <= C_RECV_CEILING_BYTES ||
            throw(ServerError("max_body_bytes must be <= $C_RECV_CEILING_BYTES bytes " *
                              "(the C receive buffer resets larger uploads before a 413 can be sent)"))
        ws_max_frame_bytes > 0 || throw(ServerError("ws_max_frame_bytes must be > 0"))
        ws_max_frame_bytes <= C_RECV_CEILING_BYTES ||
            throw(ServerError("ws_max_frame_bytes must be <= $C_RECV_CEILING_BYTES bytes"))
        poll_timeout_ms >= 0 || throw(ServerError("poll_timeout_ms must be >= 0"))
        drain_timeout_ms >= 0 || throw(ServerError("drain_timeout_ms must be >= 0"))
        header_timeout_ms >= 0 || throw(ServerError("header_timeout_ms must be >= 0"))
        max_connections >= 0 || throw(ServerError("max_connections must be >= 0"))
        workers >= 0 || throw(ServerError("workers must be >= 0"))
        workers > 0 && queue_size > 0 || workers == 0 ||
            throw(ServerError("queue_size must be > 0 when workers > 0"))
        new(Int(poll_timeout_ms), Int(max_body_bytes), Int(drain_timeout_ms),
            Int(request_timeout_ms), Int(ws_max_frame_bytes), Int(ws_idle_timeout_ms),
            Int(header_timeout_ms), Int(max_connections),
            Int(workers), Int(queue_size))
    end
end

# --- App — unified server type ---

"""
    RunState — per-instance mutable runtime, owned by App.

    Everything that changes while the server runs lives here: connection
    tracking (HTTP in-flight, WebSockets, active streams), the C manager and
    event-loop task, TLS material, lifecycle atomics, and background tasks.
    Configuration (`ServerConfig`), routes, middleware, errors and services
    are all build-phase state on `App` itself.
"""
mutable struct RunState
    running::Threads.Atomic{Bool}
    master::Union{Nothing,Task}
    url::Union{Nothing,String}
    manager::Manager
    tls::Union{Nothing,TLSConfig}
    ws_clients::Dict{Int,WSConn}
    ws_gen_ids::Dict{Ptr{Cvoid},Int}     # connection pointer → generation id (WS)
    ws_lock::Threads.SpinLock     # guards ws_clients/ws_gen_ids
    id_seq::Threads.Atomic{UInt64}       # X-Request-Id sequence
    conn_seq::Threads.Atomic{UInt64}     # Connection id sequence (HTTP async + WS)
    connections::Dict{Int,MgConnection}  # Transport-side in-flight (async): id → conn
    streams::Dict{Int,ActiveStream}      # Streaming responses drained by the loop
    conn_times::Dict{Ptr{Cvoid},Float64} # accept time per open connection (poll thread)
    awaiting_headers::Dict{Ptr{Cvoid},Float64}  # conns without a complete request yet
    conn_addr::Dict{Ptr{Cvoid},String}   # formatted peer IP, one per connection
    bg_tasks::Vector{Task}
    bg_lock::Threads.SpinLock            # guards bg_tasks (workers push)
end

RunState() = RunState(Threads.Atomic{Bool}(false), nothing, nothing, Manager(empty=true), nothing,
    Dict{Int,WSConn}(), Dict{Ptr{Cvoid},Int}(), Threads.SpinLock(),
    Threads.Atomic{UInt64}(0), Threads.Atomic{UInt64}(0),
    Dict{Int,MgConnection}(), Dict{Int,ActiveStream}(),
    Dict{Ptr{Cvoid},Float64}(), Dict{Ptr{Cvoid},Float64}(),
    Dict{Ptr{Cvoid},String}(), Task[], Threads.SpinLock())

# --- Background task tracking ---
# Workers push timed-out request tasks; the event loop prunes completed ones on
# its health tick so the vector does not grow for the server's lifetime.

@inline function bg_track!(server::AbstractServer, t::Task)
    lock(server.runtime.bg_lock)
    try
        push!(server.runtime.bg_tasks, t)
    finally
        unlock(server.runtime.bg_lock)
    end
    return t
end

function bg_prune!(server::AbstractServer)
    lock(server.runtime.bg_lock)
    try
        filter!(!istaskdone, server.runtime.bg_tasks)
    finally
        unlock(server.runtime.bg_lock)
    end
    return nothing
end

function bg_snapshot(server::AbstractServer)
    lock(server.runtime.bg_lock)
    try
        return copy(server.runtime.bg_tasks)
    finally
        unlock(server.runtime.bg_lock)
    end
end

"""
    App — Mongoose.jl web application.

    Use `workers=0` for sync (default) or `workers=N` for async worker pool.

    # Constructors
    ```julia
    app = App()                          # sync, dynamic router
    app = App(workers=4)                 # async, 4 workers
    app = App(workers=4, queue_size=2048) # async with larger queue
    app = App(router=my_router)          # bring-your-own router
    ```

    # Configuration keyword arguments
    | Keyword                | Default            | Description                            |
    |------------------------|--------------------|----------------------------------------|
    | `workers`              | `0`                | Worker threads (0 = sync)              |
    | `queue_size`           | `1024`             | Max pending requests (async only)      |
    | `poll_timeout_ms`      | `1`                | Mongoose poll interval                 |
    | `max_body_bytes`       | `MAX_BODY_BYTES`   | Max request body size                  |
    | `drain_timeout_ms`     | `DRAIN_TIMEOUT_MS` | Graceful shutdown drain                |
    | `request_timeout_ms`   | `0`                | Per-request timeout (0 = disabled)     |
    | `ws_max_frame_bytes`   | `MAX_BODY_BYTES`   | Max WebSocket frame size               |
    | `ws_idle_timeout_ms`   | `0`                | WS idle timeout (0 = disabled)         |
    | `header_timeout_ms`    | `0`                | Close conns without a complete request |
    | `max_connections`      | `0`                | Max open connections (0 = unlimited)   |
    | `router`               | `Router()`         | Custom router instance                 |
    | `tls`                  | `nothing`          | `TLSConfig` for HTTPS                  |

    # Structure (DESIGN G4)
    - `app.config` — immutable `ServerConfig`.
    - `app.runtime` — mutable `RunState` (connections, manager, loop, TLS…).
    - `app.router`, `app.middlewares`, `app.errors`, `app.services`, … —
      build-phase state; registration after `start!` throws `ServerError`.
    - `app.executor` — `SyncExecutor` or `AsyncExecutor` (the worker pool).
"""
mutable struct App{R<:AbstractRouter} <: AbstractServer
    # ── Immutable configuration ────────────────────────────────────────────────
    const config::ServerConfig

    # ── Mutable runtime (connections, loop, TLS, background tasks) ────────────
    const runtime::RunState

    # ── Build-phase routing & middleware ──────────────────────────────────────
    const router::R
    const middlewares::Vector{AbstractMiddleware}
    const mounts::Vector{Tuple{String,String}}

    # ── Build-phase error handling & DI ───────────────────────────────────────
    const errors::Dict{Int,Union{Response,Function}}
    const exception_handlers::Dict{DataType,Function}
    const services::ServiceRegistry

    # ── Build-phase lifecycle hooks ───────────────────────────────────────────
    const hooks_start::Vector{Function}
    const hooks_stop::Vector{Function}

    # ── Execution strategy: SyncExecutor (inline) or AsyncExecutor ───────────
    const executor::AbstractExecutor

    # ── Request-processing seam bundle (mirrors the build-phase containers) ──
    context::RequestContext

    function App(;
                 workers::Integer=0,
                 queue_size::Integer=1024,
                 poll_timeout_ms::Integer=1,
                 max_body_bytes::Integer=MAX_BODY_BYTES,
                 drain_timeout_ms::Integer=DRAIN_TIMEOUT_MS,
                 request_timeout_ms::Integer=0,
                 ws_max_frame_bytes::Integer=MAX_BODY_BYTES,
                 ws_idle_timeout_ms::Integer=0,
                 header_timeout_ms::Integer=0,
                 max_connections::Integer=0,
                 router::R=Router(),
                 tls::Union{Nothing,TLSConfig}=nothing,
                 errors::Dict{Int,<:Any}=Dict{Int,Union{Response,Function}}(),
                 services::NamedTuple=NamedTuple()) where {R<:AbstractRouter}

        cfg = ServerConfig(;
            poll_timeout_ms, max_body_bytes, drain_timeout_ms, request_timeout_ms,
            ws_max_frame_bytes, ws_idle_timeout_ms, header_timeout_ms, max_connections,
            workers, queue_size)

        errs = Dict{Int,Union{Response,Function}}(k => v for (k, v) in errors)
        for code in keys(errs)
            (100 <= code <= 599) || throw(ServerError("Error status code must be in [100,599], got $code"))
        end

        exec = cfg.workers > 0 ? AsyncExecutor(cfg.workers, cfg.queue_size) : SyncExecutor()
        rs = RunState()
        rs.tls = tls   # raw TLSConfig material; normalized at start!
        ex_handlers = Dict{DataType,Function}()
        used_mw = AbstractMiddleware[]
        ctx = RequestContext(router; middlewares=used_mw,
                             errors=errs, services=services,
                             exception_handlers=ex_handlers)
        return new{R}(
            cfg,
            rs,
            router,
            used_mw,
            Tuple{String,String}[],
            errs,
            ex_handlers,
            ServiceRegistry(services),
            Function[],
            Function[],
            exec,
            ctx
        )
    end
end

# --- Teardown ---

function teardown!(app::App)
    for st in values(app.runtime.streams)
        close(st.channel)
    end
    empty!(app.runtime.streams)
    free!(app.runtime.manager)
end

# --- Registration-after-start guard ---

@inline function _ensure_registratable(server::AbstractServer, what::String)
    server.runtime.running[] && throw(ServerError("cannot register $what after start!"))
    return nothing
end

# --- Registration helpers ---

"""
    onerror!(app, status, handler)
    onerror!(handler, app, status)

Register a custom error handler for a specific HTTP status code.
`handler` may be a `Response` (static) or `Function(req) → Response` (dynamic).
Both argument orders are accepted; the `(handler, app, status)` form exists so
a do-block works.

# Example
```julia
onerror!(app, 404) do req
    json(Dict("error" => "not found", "path" => req.uri); status=404)
end
```
"""
function onerror!(server::AbstractServer, status::Int, handler::Union{Response,Function})
    (100 <= status <= 599) || throw(ServerError("Status code must be in [100,599]"))
    _ensure_registratable(server, "error responses")
    server.errors[status] = handler
    return server
end
onerror!(f::Function, server::AbstractServer, status::Int) = onerror!(server, status, f)

"""
    onerror!(app, ::Type{E}, handler)

Register a typed exception handler: `handler(req, e)` returns the `Response`
for any handler/middleware error that is a `E` (or subtype). Handlers are
tried in registration order; unhandled exceptions fall through to the default
500 path.

# Example
```julia
struct NoMatch <: Exception end
onerror!(app, NoMatch) do req, e
    json(Dict("error" => "not found"); status=404)
end
```
"""
function onerror!(server::AbstractServer, ::Type{E}, handler::Function) where {E<:Exception}
    _ensure_registratable(server, "exception handlers")
    server.exception_handlers[E] = handler
    return server
end
onerror!(handler::Function, server::AbstractServer, ::Type{E}) where {E<:Exception} =
    onerror!(server, E, handler)

"""
    onstart!(app, f)
    onstart!(f, app)

Register a callback to run after the server starts (before accepting
connections). Both argument orders are accepted; the `(f, app)` form exists so
`onstart!(app) do … end` works.
"""
function onstart!(server::AbstractServer, f::Function)
    _ensure_registratable(server, "start hooks")
    push!(server.hooks_start, f)
    return server
end
onstart!(f::Function, server::AbstractServer) = onstart!(server, f)

"""
    onstop!(app, f)
    onstop!(f, app)

Register a callback to run during graceful shutdown. Both argument orders are
accepted; the `(f, app)` form exists so `onstop!(app) do … end` works.
"""
function onstop!(server::AbstractServer, f::Function)
    _ensure_registratable(server, "stop hooks")
    push!(server.hooks_stop, f)
    return server
end
onstop!(f::Function, server::AbstractServer) = onstop!(server, f)

"""
    service!(app, name, value)

Register a service for dependency injection.

```julia
service!(app, :db, MyDB.connect())
service(req, :db)      # retrieve inside handler
```
"""
function service!(app::App, name::Symbol, value)
    _ensure_registratable(app, "services")
    old = app.services.deps
    app.services.deps = (; old..., name => value)
    # Services changed → refresh the seam's snapshot (build-phase only).
    app.context = RequestContext(app.router; middlewares=app.middlewares,
                                 errors=app.errors, services=app.services.deps,
                                 exception_handlers=app.exception_handlers)
    return app
end

"""
    service(req, name) → Any
    service(req, ::Val{name}) → T
    service(req, name, T) → T

Retrieve a service by name from the request context.
- `service(req, :db)` returns the raw value (values may be zero-arg callables,
  which are invoked).
- `service(req, Val(:db))` avoids re-parsing the name, but the lookup goes
  through the dynamic request context — the return type is inferred `Any`.
- `service(req, :db, DBPool)` asserts the type and throws otherwise.

For **type-stable** access in hot paths use [`withservices`](@ref), whose
closure receives the concrete `NamedTuple`:

# Example
```julia
app = App(services=(db=pool, cache=redis))
withservices(req) do svcs
    svcs.db            # concrete: DBPool
end
db = service(req, Val(:db))   # convenient, dynamically typed
```
"""
function service(req::Request, name::Symbol)
    ctx = req.context
    ctx === nothing && return nothing
    svcs = get(ctx, :_services, nothing)
    svcs isa NamedTuple || return nothing
    hasproperty(svcs, name) || return nothing
    v = getproperty(svcs, name)
    return v isa Function ? v() : v
end

@inline function service(req::Request, ::Val{name}) where {name}
    ctx = req.context
    ctx === nothing && return nothing
    svcs = get(ctx, :_services, nothing)
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
    services(req) → NamedTuple

The request's DI services as a NamedTuple (empty when none were registered).
Dynamically typed at this boundary; use [`withservices`](@ref) for
type-stable access.
"""
function services(req::Request)
    ctx = req.context
    ctx === nothing && return NamedTuple()
    svcs = get(ctx, :_services, nothing)
    return svcs isa NamedTuple ? svcs : NamedTuple()
end

"""
    withservices(f, req) → f(services(req))

Function-barrier access to DI services: the closure receives the concrete
NamedTuple, so field access inside it specializes — unlike
`service(req, Val(:x))`, which reads through the dynamic request context.

# Example
```julia
withservices(req) do svcs
    svcs.db.query("select 1")
end
```
"""
@inline withservices(f::F, req::Request) where {F} = f(services(req))

"""
    background!(app, f)
    background!(f, app)

Schedule a background task to be spawned when `start!` is called.
`f` should be a zero-argument function. Both argument orders are accepted; the
`(f, app)` form exists so `background!(app) do … end` works.

```julia
background!(app) do
    while true
        cleanup_expired_sessions!()
        sleep(60)
    end
end
```
"""
function background!(server::AbstractServer, f::Function)
    _ensure_registratable(server, "background tasks")
    push!(server.hooks_start, () -> bg_track!(server, @async f()))
    return server
end
background!(f::Function, server::AbstractServer) = background!(server, f)

# --- Display ---

function Base.show(io::IO, app::App)
    mode = app.config.workers == 0 ? "sync" : "async($(app.config.workers) workers)"
    print(io, "App($mode, $(length(app)) routes, $(length(app.middlewares)) middleware)")
end

# --- use! (add middleware to an app) ---
# The middleware protocol (AbstractMiddleware, before/after) lives in
# Kernel; this server-layer method wires it onto an App.

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
function use!(server::AbstractServer, @nospecialize(mw); paths=nothing)
    _ensure_registratable(server, "middleware")
    inner = asmiddleware(mw)
    prefixes = String[rstrip(p, '/') for p in asstrings(paths)]
    filter!(!isempty, prefixes)
    wrapped = isempty(prefixes) ? inner : PathFilter(inner, prefixes)
    attach!(wrapped, server)
    push!(server.middlewares, wrapped)
    # Refresh the seam's baked tuple stack (registration is build-phase only).
    server.context = RequestContext(server.router; middlewares=server.middlewares,
                                    errors=server.errors,
                                    services=server.services.deps,
                                    exception_handlers=server.exception_handlers)
    return server
end

# Do-block convenience: use!(app) do req, next ... end
use!(f::Function, server::AbstractServer; paths=nothing) =
    use!(server, f; paths=paths)

# Metrics gauges: capture the server so `/metrics` can report live counts.
function attach!(mw::Metrics, server::AbstractServer)
    exec = server.executor
    mw.state = () -> (
        connections = length(server.runtime.conn_times),
        ws_clients = length(server.runtime.ws_clients),
        streams = length(server.runtime.streams),
        inflight = exec isa AsyncExecutor ? exec.inflight[] : 0,
        queue_depth = exec isa AsyncExecutor ? Base.n_avail(exec.calls) : 0,
    )
    return mw
end
