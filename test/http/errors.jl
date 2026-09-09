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

    @testset "HTTPError hierarchy" begin
        struct ErrUser
            name::String
            age::Int
        end

        s = App()
        get!(s, "/teapot") do req; throw(ImATeapotError("short and stout")) end
        get!(s, "/missing") do req; throw(NotFoundError("user 9")) end
        get!(s, "/conflict") do req; throw(ConflictError("duplicate")) end
        post!(s, "/valid") do req; validate(req, ErrUser) end

        onerror!(s, 409) do req
            json(Dict("err" => "custom conflict page"); status=409)
        end

        with_server(s) do port
            r = HTTP.get("http://127.0.0.1:$port/teapot"; status_exception=false)
            @test r.status == 418
            @test String(r.body) == "short and stout"

            r = HTTP.get("http://127.0.0.1:$port/missing"; status_exception=false)
            @test r.status == 404
            @test occursin("user 9", String(r.body))

            # Custom error page for the status wins over the exception message.
            r = HTTP.get("http://127.0.0.1:$port/conflict"; status_exception=false)
            @test r.status == 409
            @test contains(String(r.body), "custom conflict page")

            # Unhandled ValidationError maps to 422.
            r = HTTP.post("http://127.0.0.1:$port/valid"; status_exception=false,
                headers=["Content-Type" => "application/json"],
                body=JSON.json(Dict("name" => "Alice")))
            @test r.status == 422
        end
    end

    @testset "onerror! beats automatic HTTPError" begin
        s = App()
        onerror!(s, NotFoundError) do req, e
            json(Dict("err" => "custom: $(e.message)"); status=404)
        end
        get!(s, "/boom") do req; throw(NotFoundError("oops")) end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/boom"; status_exception=false)
            @test resp.status == 404
            @test contains(String(resp.body), "custom: oops")
        end
    end
end

