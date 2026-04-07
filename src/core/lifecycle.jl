"""
    Server lifecycle management — start, shutdown, graceful drain.
"""

# ---------------------------------------------------------------------------
# Base.show — human-readable display for Router and server types
# ---------------------------------------------------------------------------

function Base.show(io::IO, r::Router)
    n_fixed   = length(r.fixed)
    n_dynamic = _countnodes(r.node)
    n_ws      = length(r.ws_routes)
    print(io, "Router(")
    print(io, n_fixed + n_dynamic, " route", (n_fixed + n_dynamic) == 1 ? "" : "s")
    n_ws > 0 && print(io, ", ", n_ws, " WebSocket", n_ws == 1 ? "" : "s")
    print(io, ")")
end

# Count the number of nodes that carry at least one handler in the trie.
function _countnodes(node::TrieNode)::Int
    count = _hashandlers(node.handlers) ? 1 : 0
    for (_, child) in node.children
        count += _countnodes(child)
    end
    if node.dynamic !== nothing
        count += _countnodes(node.dynamic)
    end
    return count
end

function Base.show(io::IO, s::SyncServer)
    status = s.core.running[] ? "running" : "stopped"
    print(io, "SyncServer(", status, ", router=", s.core.router, ")")
end

function Base.show(io::IO, s::AsyncServer)
    status = s.core.running[] ? "running" : "stopped"
    print(io, "AsyncServer(", status,
          ", workers=", s.nworkers,
          ", router=", s.core.router, ")")
end

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

"""
    start!(server; host, port, blocking)

Start the Mongoose HTTP server. Initializes the manager, binds an HTTP listener,
starts worker threads (for AsyncServer), and begins the event loop.

When `blocking=true`, `InterruptException` (Ctrl+C) is caught and triggers a
graceful shutdown automatically — no wrapper code needed in the caller.

# Keyword Arguments
- `host::AbstractString`: IP address to bind to (default: `"127.0.0.1"`).
- `port::Integer`: Port number to listen on (default: `8080`).
- `blocking::Bool`: If `true`, blocks until the server is stopped (default: `true`).
"""
function start!(server::AbstractServer; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=true)
    if Threads.atomic_xchg!(server.core.running, true)
        return
    end

    try
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

# Emit a single structured startup log with everything an operator needs.
function _logstart(server::SyncServer, url::String)
    @info "Mongoose started" type="SyncServer" url=url routes=_routecount(server.core.router) julia_threads=Threads.nthreads()
end

function _logstart(server::AsyncServer, url::String)
    @info "Mongoose started" type="AsyncServer" url=url workers=server.nworkers routes=_routecount(server.core.router) julia_threads=Threads.nthreads()
end

# Total registered handler-bearing nodes across fixed + dynamic trie.
_routecount(r::Router) = length(r.fixed) + _countnodes(r.node)
_routecount(::StaticRouter) = -1  # unknown at runtime for AOT routers

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

    @info "Mongoose shutting down" server=server
    _drain(server)
    _stopworkers!(server)
    _stoploop!(server)
    _teardown!(server)
    _unregister!(server)
    @info "Mongoose stopped"
    return
end

"""
    _drain(server)

Wait for in-flight requests to drain, up to `drain_timeout`.
For AsyncServer, polls the response channels until they're empty or timeout expires.
"""
function _drain(server::AbstractServer)
    timeout_s = server.core.drain_timeout / 1000.0
    deadline = time() + timeout_s
    while time() < deadline
        _haspending(server) || break
        sleep(0.01)
    end
    return
end

_haspending(::AbstractServer) = false
