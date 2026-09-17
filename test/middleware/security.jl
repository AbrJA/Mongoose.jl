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
        use!(s, security(frame_options="SAMEORIGIN", hsts_max_age_seconds=nothing))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            headers = Dict(resp.headers)
            @test headers["X-Frame-Options"] == "SAMEORIGIN"
            @test !haskey(headers, "Strict-Transport-Security")
        end
    end

    @testset "Every optional header is disabled with nothing" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, security(hsts_max_age_seconds=nothing, frame_options=nothing,
                         content_type_options=false, referrer_policy=nothing))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            headers = Dict(resp.headers)
            for h in ("Strict-Transport-Security", "X-Frame-Options",
                      "X-Content-Type-Options", "Referrer-Policy", "Content-Security-Policy")
                @test !haskey(headers, h)
            end
        end
    end

    @testset "csp is opt-in" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, security(csp="default-src 'self'"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test Dict(resp.headers)["Content-Security-Policy"] == "default-src 'self'"
        end
    end
end

