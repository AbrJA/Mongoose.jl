@testset "CORS middleware" begin
    @testset "Preflight OPTIONS request" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors())

        with_server(s) do port
            resp = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 204
            headers = Dict(resp.headers)
            @test haskey(headers, "Access-Control-Allow-Origin")
            @test headers["Access-Control-Allow-Origin"] == "*"
        end
    end

    @testset "CORS headers on regular requests" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(origins="https://example.com"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 200
            headers = Dict(resp.headers)
            @test headers["Access-Control-Allow-Origin"] == "https://example.com"
        end
    end

    @testset "Custom CORS methods and headers" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(methods="GET, POST", headers="X-Custom", max_age=3600))

        with_server(s) do port
            resp = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 204
            headers = Dict(resp.headers)
            @test headers["Access-Control-Allow-Methods"] == "GET, POST"
            @test headers["Access-Control-Allow-Headers"] == "X-Custom"
            @test headers["Access-Control-Max-Age"] == "3600"
        end
    end
end

@testset "Rate limiting" begin
    @testset "Allows requests under limit" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=5, window_seconds=60))

        with_server(s) do port
            for _ in 1:5
                resp = HTTP.get("http://127.0.0.1:$port/";
                    status_exception=false,
                    headers=["X-Forwarded-For" => "1.2.3.4"])
                @test resp.status == 200
            end
        end
    end

    @testset "Blocks requests over limit" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=2, window_seconds=60))

        with_server(s) do port
            for _ in 1:2
                HTTP.get("http://127.0.0.1:$port/";
                    status_exception=false,
                    headers=["X-Forwarded-For" => "99.99.99.99"])
            end
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "99.99.99.99"])
            @test resp.status == 429
        end
    end

    @testset "Different IPs have independent limits" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=2, window_seconds=60))

        with_server(s) do port
            for _ in 1:2
                HTTP.get("http://127.0.0.1:$port/";
                    status_exception=false,
                    headers=["X-Forwarded-For" => "10.0.0.1"])
            end
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false,
                headers=["X-Forwarded-For" => "10.0.0.2"])
            @test resp.status == 200
        end
    end
end

@testset "Bearer auth" begin
    @testset "Valid token passes" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> token == "valid-token"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure";
                status_exception=false,
                headers=["Authorization" => "Bearer valid-token"])
            @test resp.status == 200
            @test String(resp.body) == "secret"
        end
    end

    @testset "Missing auth header returns 401" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> token == "valid-token"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure"; status_exception=false)
            @test resp.status == 401
        end
    end

    @testset "Invalid token returns 403" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> token == "valid-token"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure";
                status_exception=false,
                headers=["Authorization" => "Bearer wrong-token"])
            @test resp.status == 403
        end
    end

    @testset "Invalid scheme returns 401" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> true))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure";
                status_exception=false,
                headers=["Authorization" => "Basic abc123"])
            @test resp.status == 401
        end
    end
end

@testset "API Key auth" begin
    @testset "Valid key passes" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, apikey(keys=Set(["key-123", "key-456"])))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api";
                status_exception=false,
                headers=["X-API-Key" => "key-123"])
            @test resp.status == 200
        end
    end

    @testset "Missing key returns 401" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, apikey(keys=Set(["key-123"])))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 401
        end
    end

    @testset "Invalid key returns 401" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, apikey(keys=Set(["key-123"])))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api";
                status_exception=false,
                headers=["X-API-Key" => "wrong-key"])
            @test resp.status == 401
        end
    end
end

@testset "Logger middleware" begin
    @testset "Logs to buffer" begin
        io = IOBuffer()
        s = App()
        get!(s, "/logged") do req; text("ok") end
        use!(s, logger(output=io))

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/logged"; status_exception=false)
        end
        output = String(take!(io))
        @test contains(output, "GET")
        @test contains(output, "/logged")
        @test contains(output, "200")
    end

    @testset "Structured JSON logging" begin
        io = IOBuffer()
        s = App()
        get!(s, "/json-log") do req; text("ok") end
        use!(s, logger(output=io, structured=true))

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/json-log"; status_exception=false)
        end
        output = String(take!(io))
        lines = filter(!isempty, split(output, '\n'))
        parsed = JSON3.read(lines[end])
        @test parsed["method"] == "GET"
        @test parsed["status"] == 200
        @test haskey(parsed, "duration")
    end

    @testset "Threshold filtering" begin
        io = IOBuffer()
        s = App()
        get!(s, "/fast") do req; text("ok") end
        use!(s, logger(output=io, threshold=10000))  # 10 seconds — nothing logged

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)
        end
        @test isempty(take!(io))
    end
end

@testset "Health middleware" begin
    @testset "Default healthy" begin
        s = App()
        get!(s, "/") do req; text("app") end
        use!(s, health())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/healthz"; status_exception=false)
            @test resp.status == 200
            @test contains(String(resp.body), "healthy")

            resp2 = HTTP.get("http://127.0.0.1:$port/readyz"; status_exception=false)
            @test resp2.status == 200

            resp3 = HTTP.get("http://127.0.0.1:$port/livez"; status_exception=false)
            @test resp3.status == 200
        end
    end

    @testset "Unhealthy returns 503" begin
        s = App()
        get!(s, "/") do req; text("app") end
        use!(s, health(health_check=() -> false))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/healthz"; status_exception=false)
            @test resp.status == 503
            @test contains(String(resp.body), "unhealthy")
        end
    end

    @testset "Not ready returns 503" begin
        s = App()
        get!(s, "/") do req; text("app") end
        use!(s, health(ready_check=() -> false))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/readyz"; status_exception=false)
            @test resp.status == 503
            @test contains(String(resp.body), "not ready")
        end
    end

    @testset "Non-health routes pass through" begin
        s = App()
        get!(s, "/app") do req; text("hello") end
        use!(s, health())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/app"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "hello"
        end
    end
end

@testset "Metrics middleware" begin
    @testset "Exposes /metrics endpoint" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, metrics())

        with_server(s) do port
            for _ in 1:3
                HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            end
            resp = HTTP.get("http://127.0.0.1:$port/metrics"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "http_requests_total")
            @test contains(body, "http_request_duration_seconds")
        end
    end

    @testset "Custom metrics path" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, metrics(path="/stats"))

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            resp = HTTP.get("http://127.0.0.1:$port/stats"; status_exception=false)
            @test resp.status == 200
            @test contains(String(resp.body), "http_requests_total")
        end
    end
end

@testset "Security headers" begin
    @testset "Default security headers" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, security())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
            headers = Dict(resp.headers)
            @test headers["X-Frame-Options"] == "DENY"
            @test headers["X-Content-Type-Options"] == "nosniff"
            @test haskey(headers, "Strict-Transport-Security")
            @test haskey(headers, "Referrer-Policy")
        end
    end

    @testset "Custom security config" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, security(frame_options="SAMEORIGIN", hsts_max_age=0))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            headers = Dict(resp.headers)
            @test headers["X-Frame-Options"] == "SAMEORIGIN"
            @test !haskey(headers, "Strict-Transport-Security")
        end
    end
end

@testset "Middleware pipeline order" begin
    @testset "Middlewares execute in FIFO order" begin
        order = String[]

        struct MW1 <: Mongoose.AbstractMiddleware end
        function (::MW1)(req::Request, next::Function)
            push!(order, "before1")
            resp = next()
            push!(order, "after1")
            return resp
        end

        struct MW2 <: Mongoose.AbstractMiddleware end
        function (::MW2)(req::Request, next::Function)
            push!(order, "before2")
            resp = next()
            push!(order, "after2")
            return resp
        end

        s = App()
        get!(s, "/") do req; push!(order, "handler"); text("ok") end
        use!(s, MW1())
        use!(s, MW2())

        with_server(s) do port
            empty!(order)
            HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test order == ["before1", "before2", "handler", "after2", "after1"]
        end
    end

    @testset "Middleware short-circuit" begin
        struct BlockAll <: Mongoose.AbstractMiddleware end
        function (::BlockAll)(req::Request, next::Function)
            return Response(403, "blocked")
        end

        s = App()
        get!(s, "/") do req; text("should not reach") end
        use!(s, BlockAll())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 403
            @test String(resp.body) == "blocked"
        end
    end
end

@testset "Path-scoped middleware" begin
    s = App()
    get!(s, "/public") do req; text("public") end
    get!(s, "/admin/panel") do req; text("admin") end
    use!(s, bearer(t -> t == "secret"); paths=["/admin"])

    with_server(s) do port
        resp = HTTP.get("http://127.0.0.1:$port/public"; status_exception=false)
        @test resp.status == 200

        resp2 = HTTP.get("http://127.0.0.1:$port/admin/panel"; status_exception=false)
        @test resp2.status == 401

        resp3 = HTTP.get("http://127.0.0.1:$port/admin/panel";
            status_exception=false,
            headers=["Authorization" => "Bearer secret"])
        @test resp3.status == 200
    end
end
