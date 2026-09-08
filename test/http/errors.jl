@testset "Error handling" begin
    @testset "Handler exception returns 500" begin
        s = App()
        get!(s, "/crash") do req; error("boom") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/crash"; status_exception=false)
            @test resp.status == 500
        end
    end

    @testset "404 for unmatched routes" begin
        s = App()
        get!(s, "/exists") do req; text("ok") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/nope"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "Custom error handler via onerror!" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        onerror!(s, 404) do req
            text("custom 404"; status=404)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/nope"; status_exception=false)
            @test resp.status == 404
            @test String(resp.body) == "custom 404"
        end
    end
end

