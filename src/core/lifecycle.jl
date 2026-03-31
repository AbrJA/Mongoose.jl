"""
    Server lifecycle management — start, shutdown, graceful drain.
"""

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
        _bind!(server, host, port)
        _spawnworkers!(server)

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

"""
    shutdown!(server)

Gracefully stop the server:
1. Signal the event loop to stop.
2. Wait for in-flight requests to drain (up to `drain_timeout_ms`).
3. Stop worker threads.
4. Free all C resources.
5. Unregister from the global registry.
"""
function shutdown!(server::AbstractServer)
    if !Threads.atomic_xchg!(server.core.running, false)
        @info "Server not running. Nothing to do."
        return
    end

    @info "Stopping server..."

    _drain_in_flight(server)

    _stopworkers!(server)
    _stoploop!(server)
    _teardown!(server)
    _unregister!(server)

    @info "Server stopped successfully."
    return
end

"""
    _drain_in_flight(server)

Wait for in-flight requests to drain, up to `drain_timeout_ms`.
For AsyncServer, polls the response channels until they're empty or timeout expires.
"""
function _drain_in_flight(server::AbstractServer)
    timeout_s = server.core.drain_timeout_ms / 1000.0
    deadline = time() + timeout_s
    while time() < deadline
        _haspending(server) || break
        sleep(0.01)
    end
    return
end

_haspending(::AbstractServer) = false
