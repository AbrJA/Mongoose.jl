@testset "Middleware edge cases" begin
    struct OrderMWF <: Mongoose.AbstractMiddleware
        name::String
        order::Vector{String}
    end
    function (mw::OrderMWF)(req::Request, next::Function)
        push!(mw.order, "$(mw.name)-before")
        resp = next()
        push!(mw.order, "$(mw.name)-after")
        return resp
    end

    struct BlockMWF <: Mongoose.AbstractMiddleware end
    function (::BlockMWF)(req::Request, next::Function)
        return Response(403, "blocked")
    end

    @testset "Multiple middleware execution order" begin
        order = String[]
        s = App()
        get!(s, "/") do req; text(join(order, ",")) end
        use!(s, OrderMWF("A", order))
        use!(s, OrderMWF("B", order))

        with_server(s) do port
            empty!(order)
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
            @test order == ["A-before", "B-before", "B-after", "A-after"]
        end
    end

    @testset "Middleware short-circuit" begin
        s = App()
        get!(s, "/") do req; text("handler") end
        use!(s, BlockMWF())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 403
            @test String(resp.body) == "blocked"
        end
    end

    @testset "Rate limit window expiry" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, ratelimit(max_requests=1, window_seconds=1; trust_proxies=true))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "expire-test"])
            @test resp.status == 200

            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "expire-test"])
            @test resp.status == 429

            sleep(1.1)

            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "expire-test"])
            @test resp.status == 200
        end
    end

    @testset "Bearer auth flow" begin
        s = App()
        get!(s, "/protected") do req; text("secret") end
        use!(s, bearer(token -> token == "my-secret-token"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/protected"; status_exception=false)
            @test resp.status == 401

            resp = HTTP.get("http://127.0.0.1:$port/protected";
                status_exception=false,
                headers=["Authorization" => "Bearer wrong-token"])
            @test resp.status == 403

            resp = HTTP.get("http://127.0.0.1:$port/protected";
                status_exception=false,
                headers=["Authorization" => "Bearer my-secret-token"])
            @test resp.status == 200
            @test String(resp.body) == "secret"
        end
    end

    @testset "API key middleware" begin
        s = App()
        get!(s, "/data") do req; text("data") end
        use!(s, apikey(keys=Set(["secret123"])))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/data"; status_exception=false)
            @test resp.status == 401

            resp = HTTP.get("http://127.0.0.1:$port/data";
                status_exception=false,
                headers=["X-API-Key" => "wrong"])
            @test resp.status == 401

            resp = HTTP.get("http://127.0.0.1:$port/data";
                status_exception=false,
                headers=["X-API-Key" => "secret123"])
            @test resp.status == 200
        end
    end
end

