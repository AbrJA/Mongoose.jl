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

