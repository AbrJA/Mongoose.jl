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

