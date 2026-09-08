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

