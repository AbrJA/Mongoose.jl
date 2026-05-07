"""
    Server lifecycle management — start, shutdown, graceful drain.
"""

function Base.show(io::IO, r::Router)
    n_fixed   = length(r.fixed)
    n_dynamic = _countnodes(r.node)
    n_ws      = length(r.ws_routes)
    print(io, "Router(")
    print(io, n_fixed + n_dynamic, " route", (n_fixed + n_dynamic) == 1 ? "" : "s")
    n_ws > 0 && print(io, ", ", n_ws, " WebSocket", n_ws == 1 ? "" : "s")
    print(io, ")")
end

"""
    _countnodes(node) → Int

Count the number of trie nodes that carry at least one handler.
"""
function _countnodes(node::TrieNode)
    count = _hashandlers(node.handlers) ? 1 : 0
    for (_, child) in node.children
        count += _countnodes(child)
    end
    if node.dynamic !== nothing
        count += _countnodes(node.dynamic)
    end
    return count
end

function Base.show(io::IO, s::Server)
    status = s.core.running[] ? "running" : "stopped"
    print(io, "Server(", status, ", router=", s.core.router, ")")
end

function Base.show(io::IO, s::Async)
    status = s.core.running[] ? "running" : "stopped"
    print(io, "Async(", status,
          ", workers=", s.nworkers,
          ", router=", s.core.router, ")")
end

"""
    start!(server; host, port, blocking, tls)

Start the Mongoose HTTP server. Initializes the manager, binds an HTTP listener,
starts worker threads (for Async), and begins the event loop.

When `blocking=true`, `InterruptException` (Ctrl+C) is caught and triggers a
graceful shutdown automatically — no wrapper code needed in the caller.

# Keyword Arguments
- `host::AbstractString`: IP address to bind to (default: `"127.0.0.1"`).
- `port::Integer`: Port number to listen on (default: `8080`).
- `blocking::Bool`: If `true`, blocks until the server is stopped (default: `true`).
- `tls::Union{Nothing,TLSConfig}`: Enable HTTPS when set. Requires `cert` and `key`.
"""
function start!(server::AbstractServer; host::AbstractString="127.0.0.1", port::Integer=8080,
                blocking::Bool=true, tls::Union{Nothing,TLSConfig}=nothing)
    if Threads.atomic_xchg!(server.core.running, true)
        return
    end

    try
        server.core.tls = _normalizetls(tls)
        _register!(server)
        _init!(server)
        url = _bind!(server, host, port)
        _spawnworkers!(server)
        _logstart(server, url)

        if blocking
            # Run event loop directly on main thread (required for AOT executables)
            _eventloop(server)
        else
            _spawnloop!(server)
        end
    catch e
        shutdown!(server)
        # InterruptException (Ctrl+C) is the normal shutdown signal — don't propagate it
        e isa InterruptException || rethrow(e)
    end
    return
end

@inline _mgstr(s::String) = isempty(s) ? MgStr(C_NULL, 0) : MgStr(pointer(s), Csize_t(ncodeunits(s)))

@inline _loadtlsmaterial(value::String) = isfile(value) ? read(value, String) : value

function _normalizetls(tls::Union{Nothing,TLSConfig})
    tls === nothing && return nothing

    cert = _loadtlsmaterial(tls.cert)
    key = _loadtlsmaterial(tls.key)

    isempty(cert) && throw(ServerError("TLS cert is required when tls is enabled"))
    isempty(key) && throw(ServerError("TLS key is required when tls is enabled"))

    ca = isempty(tls.ca) ? "" : _loadtlsmaterial(tls.ca)
    return TLSConfig(
        cert = cert,
        key = key,
        ca = ca,
        name = tls.name,
        skip_verification = tls.skip_verification,
    )
end

function _inittls!(conn::MgConnection, tls::TLSConfig)
    cert = tls.cert
    key = tls.key
    ca = tls.ca
    name = tls.name

    opts = Ref(MgTlsOpts(
        _mgstr(ca),
        _mgstr(cert),
        _mgstr(key),
        _mgstr(name),
        tls.skip_verification ? Cint(1) : Cint(0),
    ))

    GC.@preserve cert key ca name begin
        mg_tls_init(conn, opts)
    end
    return
end

function _onevent!(server::AbstractServer, ::Val{MG_EV_ACCEPT}, conn::MgConnection, ::Ptr{Cvoid})
    tls = server.core.tls
    tls === nothing && return
    _inittls!(conn, tls)
    return
end

# Total registered handler-bearing nodes across fixed + dynamic trie.
_routecount(r::Router) = string(length(r.fixed) + _countnodes(r.node))
_routecount(::StaticRouter) = "static"  # routes compiled at build time via @router

"""
    shutdown!(server)

Gracefully stop the server:
1. Signal the event loop to stop.
2. Wait for in-flight requests to drain (up to `drain_timeout`).
3. Stop worker threads.
4. Free all C resources.
5. Unregister from the global registry.
"""
function shutdown!(server::AbstractServer)
    if !Threads.atomic_xchg!(server.core.running, false)
        return
    end
    _logstop(server)
    _drain(server)
    _stopworkers!(server)
    _stoploop!(server)
    _unregister!(server)
    _teardown!(server)
    _logstopped(server)
    return
end

"""
    _drain(server)

Wait for in-flight requests to drain, up to `drain_timeout`.
For Async, polls the event loop to flush replies back to clients
while waiting for workers to finish processing.
"""
function _drain(server::AbstractServer)
    timeout_s = server.core.drain_timeout / 1000.0
    deadline = time() + timeout_s
    while time() < deadline
        _haspending(server) || break
        # Keep the event loop turning so replies reach clients
        _drainpoll(server)
        sleep(0.01)
    end
    return
end

_drainpoll(::AbstractServer) = nothing

function _drainpoll(server::Async)
    mg_mgr_poll(server.core.manager.ptr, server.core.poll_timeout)
    # Flush any replies that workers produced during drain
    while isopen(server.replies) && isready(server.replies)
        res = try take!(server.replies) catch; break end
        conn = get(server.connections, res.id, nothing)
        if conn !== nothing
            if res.payload isa Response
                _sendhttp!(conn, res.payload)
                delete!(server.connections, res.id)
            else
                try _sendws!(conn, res.payload) catch end
            end
        end
    end
    mg_mgr_poll(server.core.manager.ptr, 0)
end

_haspending(::AbstractServer) = false
