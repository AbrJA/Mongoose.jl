# Shared test helpers — included by runtests.jl inside the outer @testset.

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
# A fixed sleep is unreliable on Windows where task scheduling is non-deterministic.
function wait_for_server(url; timeout=10.0, interval=0.05, kwargs...)
    deadline = time() + timeout
    while time() < deadline
        try
            # status_exception=false: any HTTP response (even 404) means server is up
            HTTP.get(url; readtimeout=1, connect_timeout=1, status_exception=false, kwargs...)
            return  # server is reachable
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
