# Shared test helpers — included by runtests.jl inside the outer @testset.

# --- Test logging ---
const TEST_VERBOSE = get(ENV, "MONGOOSE_TEST_VERBOSE", "0") == "1"

function test_log(msg::String)
    TEST_VERBOSE && println("  [TEST] ", msg)
end

# --- Dynamic port allocation (avoids port conflicts between tests) ---
const PORT_COUNTER = Threads.Atomic{Int}(15000 + (getpid() % 10000))

"""
    fresh_port() → Int

Return a unique port number for each test server. Thread-safe, monotonically increasing.
"""
function fresh_port()
    return Int(Threads.atomic_add!(PORT_COUNTER, 1))
end

"""
    with_server(server; host="127.0.0.1", kwargs...) do port ... end

Start a server on a fresh port, wait for it to be ready, yield the port,
and guarantee shutdown in the finally block. Logs port allocation for debugging hangs.
"""
function with_server(f::Function, server; host::String="127.0.0.1", timeout::Float64=15.0, kwargs...)
    port = fresh_port()
    test_log("Starting server on port $port ($(typeof(server).name.name))")
    start!(server; host=host, port=port, blocking=false, kwargs...)
    try
        wait_for_server("http://$host:$port/"; timeout=timeout)
        test_log("Server ready on port $port")
        f(port)
    finally
        shutdown!(server)
        sleep(0.05)
        test_log("Server stopped on port $port")
    end
end

"""
    signal(c::Channel) — non-blocking one-shot event signal.

    Puts `nothing` into `c` only when it is open and empty (never blocks, never
    throws). Used by tests to handshake from producer/callback code into the
    test body (SSE producers, WS callbacks).
"""
function signal(c::Channel)
    isopen(c) && !isready(c) && put!(c, nothing)
    return c
end

"""
    wait_until(f; timeout=10.0, interval=0.05) → Bool

Poll `f()` every `interval` seconds until it returns `true` (exceptions while
the condition is not ready are treated as `false`), or until `timeout`
elapses. This is the only sanctioned way to wait for transport-level readiness
(sockets, TLS handshakes): wait on a *condition*, never on a fixed wall-clock
duration to assert mid-flight state (use `Channel`/`Event` handshakes for that,
see test/http/streaming.jl).
"""
function wait_until(f::Function; timeout::Float64=10.0, interval::Float64=0.05)
    deadline = time() + timeout
    while true
        ok = try
            f()
        catch
            false
        end
        ok && return true
        time() >= deadline && return false
        sleep(interval)
    end
end

# Wait until the server is actually accepting connections.
function wait_for_server(url; timeout=10.0, kwargs...)
    ready = wait_until(timeout=Float64(timeout)) do
        HTTP.get(url; readtimeout=2, connect_timeout=2, status_exception=false, kwargs...)
        true
    end
    ready || error("Server at $url did not become ready within $(timeout)s")
end

function make_test_certificates(dir::String)
    openssl = Sys.which("openssl")
    openssl === nothing && return nothing

    cert = joinpath(dir, "server.crt")
    key = joinpath(dir, "server.key")
    cmd_key = `$(openssl) ecparam -name prime256v1 -genkey -noout -out $(key)`
    cmd_cert = `$(openssl) req -new -x509 -sha256 -key $(key) -nodes -days 1 -subj /CN=localhost -out $(cert)`

    try
        run(pipeline(cmd_key, stdout=devnull, stderr=devnull))
        run(pipeline(cmd_cert, stdout=devnull, stderr=devnull))
        return (cert, key)
    catch
        return nothing
    end
end
