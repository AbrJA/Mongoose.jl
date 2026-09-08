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

