@testset "Middleware pipeline order" begin
    @testset "Middlewares execute in FIFO order" begin
        order = String[]

        struct MW1 <: Mongoose.AbstractMiddleware end
        function (::MW1)(req::Request, next::Function)
            push!(order, "before1")
            resp = next()
            push!(order, "after1")
            return resp
        end

        struct MW2 <: Mongoose.AbstractMiddleware end
        function (::MW2)(req::Request, next::Function)
            push!(order, "before2")
            resp = next()
            push!(order, "after2")
            return resp
        end

        s = App()
        get!(s, "/") do req; push!(order, "handler"); text("ok") end
        use!(s, MW1())
        use!(s, MW2())

        with_server(s) do port
            empty!(order)
            HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test order == ["before1", "before2", "handler", "after2", "after1"]
        end
    end

    @testset "Middleware short-circuit" begin
        struct BlockAll <: Mongoose.AbstractMiddleware end
        function (::BlockAll)(req::Request, next::Function)
            return Response(403, "blocked")
        end

        s = App()
        get!(s, "/") do req; text("should not reach") end
        use!(s, BlockAll())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 403
            @test String(resp.body) == "blocked"
        end
    end

    @testset "Static middleware composition via App(middleware=…)" begin
        s = App(middleware=(cors(origins="*"), security()))
        get!(s, "/") do req; text("ok") end
        @test length(s.middlewares) == 2

        client = FakeTransport(s)
        r = client(:get, "/"; headers=["Origin" => "http://example.com"])
        @test r.status == 200
        @test get(r.headers, "access-control-allow-origin", "") == "*"
        @test get(r.headers, "x-content-type-options", "") == "nosniff"

        use!(s, etag())
        @test length(s.middlewares) == 3
        @test get(client(:get, "/").headers, "etag", "") != ""
    end
end

