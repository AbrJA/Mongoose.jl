"""
    Server lifecycle — start!, shutdown!, graceful drain, TLS.
"""

"""
    start!(app; host, port, blocking, tls)

Start the HTTP server. Initializes manager, binds listener, spawns workers (if async), runs event loop.

When `blocking=true` (default), the caller blocks until shutdown, and a
delivered `InterruptException` (Ctrl+C) triggers graceful shutdown (drain +
`onstop!` hooks) before `start!` returns. Graceful shutdown depends on Julia
delivering SIGINT as an exception to the waiting task; process managers that
only send SIGTERM bypass it.

# Example
```julia
app = App(workers=4)
get!(app, "/") do req; json(Dict("ok" => true)) end
start!(app; port=8080)
```
"""
function start!(server::AbstractServer; host::AbstractString="127.0.0.1", port::Integer=8080,
                blocking::Bool=true, tls::Union{Nothing,TLSConfig}=nothing)
    Threads.atomic_xchg!(server.runtime.running, true) && return server

    install_sigterm_handler!()
    _SIGTERM_REQUESTED[] = false
    if server.config.workers == 0 && server.config.request_timeout_ms > 0
        @log_warn "request_timeout_ms is ignored in sync mode (workers=0); " *
                  "use workers=N for per-request timeouts"
    end

    try
        server.runtime.tls = normalize_tls(tls)
        register_server!(server)
        init_server!(server)
        url = bind_server!(server, host, port)
        server.runtime.url = url

        # Run lifecycle start hooks and background tasks
        for hook in server.hooks_start
            try hook() catch e; @log_error "onstart! hook error" e catch_backtrace() end
        end

        start!(server.executor, server)
        log_server_start(server, url)

        if blocking
            # Run the loop on its own task and wait on the task from here. The
            # loop spends most of its time inside the raw `mg_mgr_poll` ccall,
            # which Julia cannot preempt; driving it from the calling task (as
            # before) left Ctrl+C undeliverable. Waiting on the task keeps this
            # thread at a Julia safe point where a received SIGINT can surface
            # as `InterruptException` and unwind to graceful shutdown.
            spawn_event_loop!(server)
            try
                wait(server.runtime.master)
            catch e
                e isa InterruptException || rethrow(e)
            finally
                shutdown!(server)
            end
        else
            spawn_event_loop!(server)
        end
    catch e
        server.runtime.running[] && shutdown!(server)
        e isa InterruptException || rethrow(e)
    end

    return server
end

"""
    shutdown!(server)

Gracefully stop the server: drain requests, stop workers, free resources.
In-flight requests and tracked background tasks (see `background!`, and
over-budget handlers from `request_timeout_ms`) get one shared grace period of
`drain_timeout_ms` ms before teardown; tasks still running after it are left
alone, completed ones are dropped.
"""
function shutdown!(server::AbstractServer)
    Threads.atomic_xchg!(server.runtime.running, false) || return
    log_server_stop(server)

    # Run lifecycle stop hooks
    for hook in server.hooks_stop
        try hook() catch e; @log_error "onstop! hook error" e catch_backtrace() end
    end

    drain!(server)
    exec = server.executor
    exec isa AsyncExecutor ?
        stop!(exec; timeout=server.config.drain_timeout_ms / 1000.0) :
        stop!(exec)
    drain_bg_tasks!(server)
    stop_event_loop!(server)
    unregister_server!(server)
    server.runtime.url = nothing
    teardown!(server)
    log_server_stopped(server)
end

# --- Internal lifecycle helpers ---

function bind_server!(server::AbstractServer, host::AbstractString, port::Integer)
    scheme = server.runtime.tls === nothing ? "http" : "https"
    url = "$scheme://$host:$port"
    fn_data = Ptr{Cvoid}(objectid(server))
    listener = mg_http_listen(server.runtime.manager.ptr, url, get_c_callback(), fn_data)
    listener == C_NULL && throw(BindError("Failed to bind to $url. Port may be in use."))
    return url
end

function spawn_event_loop!(server::AbstractServer)
    server.runtime.master = @async begin
        try
            event_loop(server)
        catch e
            e isa InterruptException || @log_error "Event loop error" e catch_backtrace()
        finally
            if _SIGTERM_REQUESTED[] && server.runtime.running[]
                # Signal-initiated shutdown: run the graceful path from the loop
                # task (stop_event_loop! detects it is the current task).
                shutdown!(server)
            else
                server.runtime.running[] = false
            end
        end
    end
end

function stop_event_loop!(server::AbstractServer)
    master = server.runtime.master
    master === nothing && return
    # `shutdown!` may be called from the loop task itself (SIGTERM path); never
    # wait on the current task.
    current_task() === master || (try wait(master) catch end)
    server.runtime.master = nothing
end

function drain!(server::AbstractServer)
    deadline = time() + server.config.drain_timeout_ms / 1000.0
    while time() < deadline
        haspending(server) || break
        drain_poll!(server)
        yield()
    end
    # Flush final bytes (e.g. a stream's terminal chunk) before teardown:
    # mg_send only buffers, mg_mgr_poll is what writes them to the socket.
    drain_poll!(server)
end

# Background tasks get the same one-shot `drain_timeout_ms` budget as streams:
# a `background!` loop usually never finishes, so the wait is a grace period,
# not a join. Called after `stop!(executor)` so no worker can push a new
# timed-out request task while the snapshot is taken.
function drain_bg_tasks!(server::AbstractServer)
    tasks = bg_snapshot(server)
    isempty(tasks) && return
    deadline = time() + server.config.drain_timeout_ms / 1000.0
    for t in tasks
        istaskdone(t) && continue
        remaining = deadline - time()
        remaining <= 0 && break
        timedwait(() -> istaskdone(t), remaining; pollint=0.01)
    end
    bg_prune!(server)
    return
end

# Defaults (overridden for async App)
haspending(::AbstractServer) = false
drain_poll!(server::AbstractServer) = yield()

# --- TLS Material Loading ---

@inline _is_pem(v::String) = occursin("-----BEGIN ", v) && occursin("-----END ", v)
@inline _is_path(v::String) = !isempty(v) && (occursin('/', v) || occursin('\\', v) || startswith(v, ".") || startswith(v, "~") || occursin(r"\.[A-Za-z0-9]{1,8}$", v))

function load_tls_material(value::Vector{UInt8}; field::String="")
    return value
end

function load_tls_material(value::String; field::String="")
    isempty(value) && return ""
    path = expanduser(value)
    isfile(path) && return read(path)
    _is_path(value) && throw(ServerError("$field file not found: $value"))
    _is_pem(value) && return value
    throw(ServerError("$field must be a PEM string, file path, or Vector{UInt8}"))
end

function normalize_tls(tls::Nothing)
    return nothing
end

function normalize_tls(tls::TLSConfig)
    isempty(tls.cert) && throw(ServerError("TLS cert is required"))
    isempty(tls.key) && throw(ServerError("TLS key is required"))
    return TLSConfig(
        cert = load_tls_material(tls.cert; field="TLS cert"),
        key = load_tls_material(tls.key; field="TLS key"),
        ca = isempty(tls.ca) ? "" : load_tls_material(tls.ca; field="TLS ca"),
        name = tls.name,
        skip_verification = tls.skip_verification,
    )
end

@inline _to_mgstr(s::String) = isempty(s) ? MgStr(C_NULL, 0) : MgStr(pointer(s), Csize_t(ncodeunits(s)))
@inline _to_mgstr(bytes::Vector{UInt8}) = isempty(bytes) ? MgStr(C_NULL, 0) : MgStr(pointer(bytes), Csize_t(length(bytes)))

function init_tls!(conn::MgConnection, tls::TLSConfig)
    cert, key, ca, name = tls.cert, tls.key, tls.ca, tls.name
    opts = Ref(MgTlsOpts(
        _to_mgstr(ca), _to_mgstr(cert), _to_mgstr(key), _to_mgstr(name),
        tls.skip_verification ? Cint(1) : Cint(0)
    ))
    GC.@preserve cert key ca name begin
        mg_tls_init(conn, opts)
    end
end
