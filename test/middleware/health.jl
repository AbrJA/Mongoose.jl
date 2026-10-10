@testset "Health middleware" begin
    @testset "Default healthy" begin
        s = App()
        get!(s, "/") do req; text("app") end
        s = use(s, health())

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
        s = use(s, health(health_check=() -> false))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/healthz"; status_exception=false)
            @test resp.status == 503
            @test contains(String(resp.body), "unhealthy")
        end
    end

    @testset "Not ready returns 503" begin
        s = App()
        get!(s, "/") do req; text("app") end
        s = use(s, health(ready_check=() -> false))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/readyz"; status_exception=false)
            @test resp.status == 503
            @test contains(String(resp.body), "not ready")
        end
    end

    @testset "Custom probe paths" begin
        s = App()
        get!(s, "/") do req; text("app") end
        s = use(s, health(health_path="/health", ready_path="/ready", live_path=nothing))

        with_server(s) do port
            @test HTTP.get("http://127.0.0.1:$port/health"; status_exception=false).status == 200
            @test HTTP.get("http://127.0.0.1:$port/ready"; status_exception=false).status == 200
            # Defaults are replaced; disabled endpoints pass through (404 here).
            @test HTTP.get("http://127.0.0.1:$port/healthz"; status_exception=false).status == 404
            @test HTTP.get("http://127.0.0.1:$port/livez"; status_exception=false).status == 404
        end
    end

    @testset "Non-health routes pass through" begin
        s = App()
        get!(s, "/app") do req; text("hello") end
        s = use(s, health())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/app"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "hello"
        end
    end
end

