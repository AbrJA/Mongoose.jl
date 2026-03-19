"""
    Server lifecycle management — start, shutdown, graceful drain.
"""

"""
    start!(server; host, port, blocking)

Start the Mongoose HTTP server. Initializes the manager, binds an HTTP listener,
starts worker threads (for AsyncServer), and begins the event loop.

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
        register!(server)
        setup_resources!(server)
        setup_listener!(server, host, port)
        start_workers!(server)

        if blocking
            # Run event loop directly on main thread (required for AOT executables)
            run_event_loop(server)
        else
            start_master!(server)
        end
    catch e
        shutdown!(server)
        rethrow(e)
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

    # Drain in-flight requests up to drain_timeout_ms
    _drain_in_flight(server)

    stop_workers!(server)
    stop_master!(server)
    free_resources!(server)
    unregister!(server)

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
        _has_pending(server) || break
        sleep(0.01)
    end
    return
end

_has_pending(::AbstractServer) = false
