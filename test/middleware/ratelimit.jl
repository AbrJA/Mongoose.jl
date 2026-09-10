@testset "Rate limiting" begin
    @testset "Allows requests under limit" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=5, window_seconds=60; trust_proxies=true))

        with_server(s) do port
            for _ in 1:5
                resp = HTTP.get("http://127.0.0.1:$port/";
                    status_exception=false, retry=false,
                    headers=["X-Forwarded-For" => "1.2.3.4"])
                @test resp.status == 200
            end
        end
    end

    @testset "Blocks requests over limit" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=2, window_seconds=60; trust_proxies=true))

        with_server(s) do port
            for _ in 1:2
                HTTP.get("http://127.0.0.1:$port/";
                    status_exception=false, retry=false,
                    headers=["X-Forwarded-For" => "99.99.99.99"])
            end
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "99.99.99.99"])
            @test resp.status == 429
            @test get(Dict(resp.headers), "Retry-After", "") == "60"
        end
    end

    @testset "Different IPs have independent limits" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=2, window_seconds=60; trust_proxies=true))

        with_server(s) do port
            for _ in 1:2
                HTTP.get("http://127.0.0.1:$port/";
                    status_exception=false, retry=false,
                    headers=["X-Forwarded-For" => "10.0.0.1"])
            end
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "10.0.0.2"])
            @test resp.status == 200
        end
    end

    @testset "Proxy headers not trusted by default" begin
        # With trust_proxies=false the default key is the real remote address:
        # spoofed X-Forwarded-For headers cannot evade the limit.
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=2, window_seconds=60))

        with_server(s) do port
            for ip in ["100.0.0.1", "100.0.0.2", "100.0.0.3"]
                resp = HTTP.get("http://127.0.0.1:$port/";
                    status_exception=false, retry=false,
                    headers=["X-Forwarded-For" => ip])
            end
            # Third request (any spoofed "IP") is blocked — all hit the same
            # real 127.0.0.1 bucket.
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "100.0.0.9"])
            @test resp.status == 429
        end
    end

    @testset "Default buckets per remote address (no proxies)" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=2, window_seconds=60))
        client = Mongoose.TestClient(s)

        r = client(:get, "/"); @test r.status == 200
        r = client(:get, "/"); @test r.status == 200
        r = client(:get, "/")
        @test r.status == 429                      # same IP → limited
        r = client(:get, "/"; remote_addr="10.0.0.9")
        @test r.status == 200                      # different IP → independent

        # No address available → shared fallback bucket (never per-client).
        server = App()
        get!(server, "/") do req; text("ok") end
        use!(server, ratelimit(max_requests=1, window_seconds=60))
        tc = Mongoose.TestClient(server)
        @test tc(:get, "/"; remote_addr=nothing).status == 200
        @test tc(:get, "/"; remote_addr=nothing).status == 429
    end

    @testset "Custom key_fn buckets by header" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=2, window_seconds=60,
                          key_fn=req -> get(req.headers, "x-api-key", "none")))

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/"; status_exception=false, retry=false,
                     headers=["X-Api-Key" => "key-a"])
            HTTP.get("http://127.0.0.1:$port/"; status_exception=false, retry=false,
                     headers=["X-Api-Key" => "key-a"])
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false,
                            retry=false, headers=["X-Api-Key" => "key-a"])
            @test resp.status == 429
            # A different key is unaffected.
            other = HTTP.get("http://127.0.0.1:$port/"; status_exception=false,
                             retry=false, headers=["X-Api-Key" => "key-b"])
            @test other.status == 200
        end
    end
end