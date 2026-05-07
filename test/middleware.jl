@testset "CORS Middleware" begin
    router = Router()
    route!(router, :get, "/api/data", (req) -> Response(Json, "{\"ok\":true}"))

    server = Async(router; nworkers=1)
    plug!(server, cors(origins="https://example.com"))
    start!(server, port=8096, blocking=false)
    wait_for_server("http://localhost:8096/")

    try
        response = HTTP.get("http://localhost:8096/api/data")
        @test response.status == 200
        headers_dict = Dict(String(h.first) => String(h.second) for h in response.headers)
        @test haskey(headers_dict, "Access-Control-Allow-Origin")
        @test headers_dict["Access-Control-Allow-Origin"] == "https://example.com"

        response = HTTP.request("OPTIONS", "http://localhost:8096/api/data"; status_exception=false)
        @test response.status == 204
    finally
        shutdown!(server)
    end
end

@testset "Async Middleware" begin
    router = Router()
    route!(router, :get, "/api/data", (req) -> Response(200, "Content-Type: application/json\r\n", "{\"ok\":true}"))

    server = Async(router; nworkers=2)
    plug!(server, cors(origins="https://test.com"))
    start!(server; port=8104, blocking=false)
    wait_for_server("http://localhost:8104/")

    try
        response = HTTP.get("http://localhost:8104/api/data")
        @test response.status == 200
        headers_dict = Dict(String(h.first) => String(h.second) for h in response.headers)
        @test headers_dict["Access-Control-Allow-Origin"] == "https://test.com"
    finally
        shutdown!(server)
    end
end

@testset "Authentication Middleware" begin
    router = Router()
    route!(router, :get, "/secure", (req) -> Response(200, "", "Secret Data"))

    # 1. Bearer Auth
    server_bearer = Async(router; nworkers=1)
    plug!(server_bearer, bearer(token -> token == "magic-token"))
    start!(server_bearer; port=8105, blocking=false)
    wait_for_server("http://localhost:8105/")

    try
        resp = HTTP.get("http://localhost:8105/secure"; headers=["Authorization" => "Bearer magic-token"])
        @test resp.status == 200
        @test String(resp.body) == "Secret Data"

        resp = HTTP.get("http://localhost:8105/secure"; headers=["Authorization" => "Bearer wrong"], status_exception=false)
        @test resp.status == 403

        resp = HTTP.get("http://localhost:8105/secure"; status_exception=false)
        @test resp.status == 401
    finally
        shutdown!(server_bearer)
    end

    # 2. API Key Auth
    server_api = Async(router; nworkers=1)
    plug!(server_api, apikey(keys=Set(["key123"])))
    start!(server_api; port=8106, blocking=false)
    wait_for_server("http://localhost:8106/")

    try
        resp = HTTP.get("http://localhost:8106/secure"; headers=["X-API-Key" => "key123"])
        @test resp.status == 200

        resp = HTTP.get("http://localhost:8106/secure"; headers=["X-API-Key" => "wrong"], status_exception=false)
        @test resp.status == 401
    finally
        shutdown!(server_api)
    end
end

@testset "Rate Limiting Middleware" begin
    router = Router()
    route!(router, :get, "/limited", (req) -> Response(200, "", "OK"))

    server = Async(router; nworkers=1)
    plug!(server, ratelimit(max_requests=3, window_seconds=10))
    start!(server; port=8107, blocking=false)
    wait_for_server("http://localhost:8107/")

    try
        @test HTTP.get("http://localhost:8107/limited").status == 200
        @test HTTP.get("http://localhost:8107/limited").status == 200

        resp = HTTP.get("http://localhost:8107/limited"; status_exception=false)
        @test resp.status == 429
        @test haskey(Dict(resp.headers), "Retry-After")
    finally
        shutdown!(server)
    end
end

@testset "Logger Middleware" begin
    router = Router()
    route!(router, :get, "/logged", (req) -> Response(200, "", "OK"))

    log_buf = IOBuffer()
    server = Async(router; nworkers=1)
    plug!(server, logger(output=log_buf))
    start!(server; port=8110, blocking=false)
    wait_for_server("http://localhost:8110/")

    try
        resp = HTTP.get("http://localhost:8110/logged")
        @test resp.status == 200
        sleep(0.2)

        log_output = String(take!(log_buf))
        @test occursin("GET", log_output)
        @test occursin("/logged", log_output)
        @test occursin("200", log_output)
        @test occursin("ms)", log_output)
    finally
        shutdown!(server)
    end
end

@testset "Logger Threshold" begin
    router = Router()
    route!(router, :get, "/fast", (req) -> Response(200, "", "OK"))

    log_buf = IOBuffer()
    server = Async(router; nworkers=1)
    plug!(server, logger(threshold=5000, output=log_buf))
    start!(server; port=8111, blocking=false)
    wait_for_server("http://localhost:8111/")

    try
        resp = HTTP.get("http://localhost:8111/fast")
        @test resp.status == 200
        sleep(0.2)

        log_output = String(take!(log_buf))
        @test isempty(log_output)
    finally
        shutdown!(server)
    end
end

@testset "Health Middleware" begin
    router = Router()
    route!(router, :get, "/api", (req) -> Response(200, "", "ok"))

    s1 = Server(router)
    plug!(s1, health(health_check=() -> true, ready_check=() -> true, live_check=() -> true))
    start!(s1; port=8124, blocking=false)
    wait_for_server("http://localhost:8124/")

    try
        resp = HTTP.get("http://localhost:8124/healthz")
        @test resp.status == 200
        @test occursin("healthy", String(resp.body))

        resp = HTTP.get("http://localhost:8124/readyz")
        @test resp.status == 200
        @test occursin("ready", String(resp.body))

        resp = HTTP.get("http://localhost:8124/livez")
        @test resp.status == 200
        @test occursin("alive", String(resp.body))

        resp = HTTP.get("http://localhost:8124/api")
        @test resp.status == 200
    finally
        shutdown!(s1)
    end

    s2 = Server(router)
    plug!(s2, health(health_check=() -> false))
    start!(s2; port=8125, blocking=false)
    wait_for_server("http://localhost:8125/")

    try
        resp = HTTP.get("http://localhost:8125/healthz"; status_exception=false)
        @test resp.status == 503
        @test occursin("unhealthy", String(resp.body))
    finally
        shutdown!(s2)
    end
end

@testset "Bearer Token Case-Insensitive Scheme" begin
    router = Router()
    route!(router, :get, "/secure", (req) -> Response(200, "", "ok"))

    server = Server(router)
    plug!(server, bearer(token -> token == "secret"))
    start!(server; port=8128, blocking=false)
    wait_for_server("http://localhost:8128/")

    try
        resp = HTTP.get("http://localhost:8128/secure"; headers=["Authorization" => "bearer secret"])
        @test resp.status == 200

        resp = HTTP.get("http://localhost:8128/secure"; headers=["Authorization" => "BEARER secret"])
        @test resp.status == 200

        resp = HTTP.get("http://localhost:8128/secure"; headers=["Authorization" => "bearer wrong"], status_exception=false)
        @test resp.status == 403
    finally
        shutdown!(server)
    end
end

@testset "Rate Limit X-Forwarded-For" begin
    router = Router()
    route!(router, :get, "/limited", (req) -> Response(200, "", "OK"))

    server = Async(router; nworkers=1)
    plug!(server, ratelimit(max_requests=2, window_seconds=60))
    start!(server; port=8129, blocking=false)
    wait_for_server("http://localhost:8129/")

    try
        headers1 = ["X-Forwarded-For" => "10.0.0.1"]
        headers2 = ["X-Forwarded-For" => "10.0.0.1, proxy1.example.com"]

        @test HTTP.get("http://localhost:8129/limited"; headers=headers1).status == 200
        @test HTTP.get("http://localhost:8129/limited"; headers=headers2).status == 200

        resp = HTTP.get("http://localhost:8129/limited"; headers=headers1, status_exception=false)
        @test resp.status == 429
    finally
        shutdown!(server)
    end
end

@testset "PathFilter via plug! paths keyword" begin
    router = Router()
    route!(router, :get, "/api/data",    req -> Response(200, "", "api"))
    route!(router, :get, "/public/page", req -> Response(200, "", "public"))

    server = Async(router; nworkers=1)
    plug!(server, bearer(token -> token == "secret"); paths=["/api"])
    start!(server; port=8203, blocking=false)
    wait_for_server("http://localhost:8203/")

    try
        resp = HTTP.get("http://localhost:8203/public/page")
        @test resp.status == 200
        @test String(resp.body) == "public"

        resp = HTTP.get("http://localhost:8203/api/data"; status_exception=false)
        @test resp.status == 401

        resp = HTTP.get("http://localhost:8203/api/data";
                        headers=["Authorization" => "Bearer secret"])
        @test resp.status == 200
    finally
        shutdown!(server)
    end
end

@testset "Metrics Middleware" begin
    router = Router()
    route!(router, :get,  "/api/hello", req -> Response(200, "", "hello"))
    route!(router, :post, "/api/data",  req -> Response(201, "", "created"))

    server = Async(router; nworkers=2)
    plug!(server, metrics())
    start!(server; port=8204, blocking=false)
    wait_for_server("http://localhost:8204/")

    try
        HTTP.get("http://localhost:8204/api/hello")
        HTTP.get("http://localhost:8204/api/hello")
        HTTP.post("http://localhost:8204/api/data")

        resp = HTTP.get("http://localhost:8204/metrics")
        @test resp.status == 200
        hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
        @test occursin("text/plain", hdrs["Content-Type"])

        body = String(resp.body)
        @test occursin("http_requests_total",             body)
        @test occursin("http_request_duration_seconds",   body)
        @test occursin("# TYPE http_requests_total",      body)
        @test occursin("method=\"GET\",status=\"200\"} 2", body)
        @test occursin("method=\"POST\",status=\"201\"} 1", body)
        @test occursin("http_request_duration_seconds_count", body)
    finally
        shutdown!(server)
    end
end

@testset "Structured Logger (JSON) via live server" begin
    router = Router()
    route!(router, :get, "/log_me", req -> Response(200, "", "ok"))

    log_buf = IOBuffer()
    server  = Async(router; nworkers=1)
    plug!(server, logger(structured=true, output=log_buf))
    start!(server; port=8205, blocking=false)
    wait_for_server("http://localhost:8205/")

    try
        HTTP.get("http://localhost:8205/log_me")
        sleep(0.2)

        out = String(take!(log_buf))
        @test occursin("{\"method\":",    out)
        @test occursin("\"GET\"",         out)
        @test occursin("/log_me",         out)
        @test occursin("\"status\":200",  out)
        @test occursin("\"duration\":", out)
    finally
        shutdown!(server)
    end
end

@testset "Multiple middlewares stacked: CORS + bearer auth" begin
    router = Router()
    route!(router, :get, "/api/secure", req -> Response(200, "", "secure data"))

    server = Async(router; nworkers=1)
    plug!(server, cors(origins="https://app.example.com"))
    plug!(server, bearer(token -> token == "tok123"))
    start!(server; port=8207, blocking=false)
    start!(server; port=8207, blocking=false)
    wait_for_server("http://localhost:8207/")

    try
        resp = HTTP.get("http://localhost:8207/api/secure";
                        headers=["Authorization" => "Bearer wrong"],
                        status_exception=false)
        @test resp.status == 403
        hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
        @test haskey(hdrs, "Access-Control-Allow-Origin")
        @test hdrs["Access-Control-Allow-Origin"] == "https://app.example.com"

        resp = HTTP.get("http://localhost:8207/api/secure";
                        headers=["Authorization" => "Bearer tok123"])
        @test resp.status == 200
        hdrs2 = Dict(String(h.first) => String(h.second) for h in resp.headers)
        @test hdrs2["Access-Control-Allow-Origin"] == "https://app.example.com"
    finally
        shutdown!(server)
    end
end

@testset "API key with custom header_name" begin
    router = Router()
    route!(router, :get, "/data", req -> Response(200, "", "secret"))

    server = Server(router)
    plug!(server, apikey(header_name="X-Token", keys=Set(["valid-key"])))
    start!(server; port=8215, blocking=false)
    wait_for_server("http://localhost:8215/")

    try
        resp = HTTP.get("http://localhost:8215/data";
                        headers=["X-Token" => "valid-key"])
        @test resp.status == 200

        resp = HTTP.get("http://localhost:8215/data";
                        headers=["X-API-Key" => "valid-key"],
                        status_exception=false)
        @test resp.status == 401

        resp = HTTP.get("http://localhost:8215/data"; status_exception=false)
        @test resp.status == 401
    finally
        shutdown!(server)
    end
end

@testset "CORS default wildcard origin *" begin
    router = Router()
    route!(router, :get, "/open", req -> Response(200, "", "open"))

    server = Server(router)
    plug!(server, cors())
    start!(server; port=8216, blocking=false)
    wait_for_server("http://localhost:8216/")

    try
        resp = HTTP.get("http://localhost:8216/open")
        @test resp.status == 200
        hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
        @test haskey(hdrs, "Access-Control-Allow-Origin")
        @test hdrs["Access-Control-Allow-Origin"] == "*"
        @test haskey(hdrs, "Access-Control-Allow-Methods")
        @test haskey(hdrs, "Access-Control-Allow-Headers")
    finally
        shutdown!(server)
    end
end

@testset "Server + ratelimit middleware (SpinLock)" begin
    router = Router()
    route!(router, :get, "/", req -> Response(Plain, "ok"))

    server = Server(router)
    plug!(server, ratelimit(max_requests=3, window_seconds=60))
    start!(server; port=8230, blocking=false)
    wait_for_server("http://localhost:8230/")

    try
        resp1 = HTTP.get("http://localhost:8230/")
        @test resp1.status == 200
        resp2 = HTTP.get("http://localhost:8230/")
        @test resp2.status == 200
        resp3 = HTTP.get("http://localhost:8230/"; status_exception=false)
        @test resp3.status == 429
    finally
        shutdown!(server)
    end
end

@testset "Server + metrics middleware (SpinLock)" begin
    router = Router()
    route!(router, :get, "/ping", req -> Response(Plain, "pong"))

    server = Server(router)
    plug!(server, metrics())
    start!(server; port=8231, blocking=false)
    wait_for_server("http://localhost:8231/")

    try
        HTTP.get("http://localhost:8231/ping")
        HTTP.get("http://localhost:8231/ping")

        resp = HTTP.get("http://localhost:8231/metrics")
        body = String(resp.body)
        @test occursin("http_requests_total", body)
        @test occursin("method=\"GET\"", body)
    finally
        shutdown!(server)
    end
end

@testset "Health middleware: partial failure states" begin
    router = Router()

    s1 = Server(router)
    plug!(s1, health(health_check=() -> true, ready_check=() -> false, live_check=() -> true))
    start!(s1; port=8221, blocking=false)
    wait_for_server("http://localhost:8221/")

    try
        resp = HTTP.get("http://localhost:8221/healthz"; status_exception=false)
        @test resp.status == 503
        @test occursin("unhealthy", String(resp.body))

        resp = HTTP.get("http://localhost:8221/readyz"; status_exception=false)
        @test resp.status == 503
        @test occursin("not ready", String(resp.body))

        resp = HTTP.get("http://localhost:8221/livez")
        @test resp.status == 200
        @test occursin("alive", String(resp.body))
    finally
        shutdown!(s1)
    end

    s2 = Server(router)
    plug!(s2, health(live_check=() -> false))
    start!(s2; port=8222, blocking=false)

    try
        resp = HTTP.get("http://localhost:8222/livez"; status_exception=false)
        @test resp.status == 503
        @test occursin("dead", String(resp.body))
    finally
        shutdown!(s2)
    end
end
