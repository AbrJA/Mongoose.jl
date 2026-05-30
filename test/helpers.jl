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

function greet(request)
    body = "{\"message\":\"Hello World from Julia!\"}"
    Response(Json, body)
end

function echo(request, name)
    body = "Hello $name from Julia!"
    Response(body)
end

function error_handler(request, args...)
    error("Something went wrong!")
end

# Wait until the server is actually accepting connections.
function wait_for_server(url; timeout=10.0, interval=0.05, kwargs...)
    deadline = time() + timeout
    while time() < deadline
        try
            HTTP.get(url; readtimeout=2, connect_timeout=2, status_exception=false, kwargs...)
            return
        catch
            sleep(interval)
        end
    end
    error("Server at $url did not become ready within $(timeout)s")
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
