"""
    Server lifecycle — start!, shutdown!, graceful drain, TLS.
"""

"""
    start!(app; host, port, blocking, tls)

Start the HTTP server. Initializes manager, binds listener, spawns workers (if async), runs event loop.

When `blocking=true` (default), `InterruptException` (Ctrl+C) triggers graceful shutdown.

# Example
```julia
app = App(workers=4)
get!(app, "/") do req; json(Dict("ok" => true)) end
start!(app; port=8080)
```
"""
function start!(server::AbstractServer; host::AbstractString="127.0.0.1", port::Integer=8080,
                blocking::Bool=true, tls::Union{Nothing,TLSConfig}=nothing)
    Threads.atomic_xchg!(server.running, true) && return

    try
        server.tls = normalize_tls(tls)
        register_server!(server)
        init_server!(server)
        url = bind_server!(server, host, port)

        # Run lifecycle start hooks and background tasks
        for hook in server.hooks_start
            try hook() catch e; @log_error "onstart! hook error" e catch_backtrace() end
        end

        if server.workers > 0
            spawn_workers!(server)
        end
        log_server_start(server, url)

        if blocking
            try
                event_loop(server)
            catch e
                e isa InterruptException || rethrow(e)
            finally
                shutdown!(server)
            end
        else
            spawn_event_loop!(server)
        end
    catch e
        server.running[] && shutdown!(server)
        e isa InterruptException || rethrow(e)
    end
end

"""
    shutdown!(server)

Gracefully stop the server: drain requests, stop workers, free resources.
"""
function shutdown!(server::AbstractServer)
    Threads.atomic_xchg!(server.running, false) || return
    log_server_stop(server)

    # Run lifecycle stop hooks
    for hook in server.hooks_stop
        try hook() catch e; @log_error "onstop! hook error" e catch_backtrace() end
    end

    drain!(server)
    if server.workers > 0
        stop_workers!(server)
    end
    stop_event_loop!(server)
    unregister_server!(server)
    teardown!(server)
    log_server_stopped(server)
end

# --- Internal lifecycle helpers ---

function bind_server!(server::AbstractServer, host::AbstractString, port::Integer)
    scheme = server.tls === nothing ? "http" : "https"
    url = "$scheme://$host:$port"
    fn_data = Ptr{Cvoid}(objectid(server))
    listener = mg_http_listen(server.manager.ptr, url, get_c_callback(), fn_data)
    listener == C_NULL && throw(BindError("Failed to bind to $url. Port may be in use."))
    return url
end

function spawn_event_loop!(server::AbstractServer)
    server.master = @async begin
        try
            event_loop(server)
        catch e
            e isa InterruptException || @log_error "Event loop error" e catch_backtrace()
        finally
            server.running[] = false
        end
    end
end

function stop_event_loop!(server::AbstractServer)
    master = server.master
    master === nothing && return
    try wait(master) catch end
    server.master = nothing
end

function drain!(server::AbstractServer)
    deadline = time() + server.drain_timeout / 1000.0
    while time() < deadline
        has_pending(server) || break
        drain_poll!(server)
        yield()
    end
end

# Defaults (overridden for async App)
has_pending(::AbstractServer) = false
drain_poll!(server::AbstractServer) = (server.workers > 0 && drain_poll!(server); yield())
spawn_workers!(::AbstractServer) = nothing
stop_workers!(::AbstractServer) = nothing

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
