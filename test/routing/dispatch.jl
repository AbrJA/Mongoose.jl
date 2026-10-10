@testset "Route dispatch (integration)" begin
    @testset "Fixed route dispatch" begin
        app = App()
        get!(app, "/hello") do req; text("world") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/hello"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "world"
        end
    end

    @testset "Parametric Int dispatch" begin
        app = App()
        get!(app, "/users/:id::Int") do req, id; text("User $id type=$(typeof(id))") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/users/42"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "User 42 type=Int64"
        end
    end

    @testset "Parametric String dispatch" begin
        app = App()
        get!(app, "/posts/:slug") do req, slug; text("Post: $slug") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/posts/hello-world"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "Post: hello-world"
        end
    end

    @testset "Wildcard catch-all" begin
        app = App()
        get!(app, "/files/*path") do req, path; text("Path: $path") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/files/docs/readme.md"; status_exception=false)
            @test resp.status == 200
            @test contains(String(resp.body), "docs/readme.md")
        end
    end

    @testset "404 on unregistered route" begin
        app = App()
        get!(app, "/exists") do req; text("ok") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/nope"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "405 method not allowed" begin
        app = App()
        get!(app, "/only-get") do req; text("ok") end
        with_server(app) do port
            resp = HTTP.request("POST", "http://127.0.0.1:$port/only-get"; status_exception=false)
            @test resp.status == 405
        end
    end

    @testset "Multiple params" begin
        app = App()
        get!(app, "/org/:org/repo/:repo") do req, org, repo; text("$org/$repo") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/org/julia/repo/mongoose"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "julia/mongoose"
        end
    end

    @testset "Invalid typed param returns 400" begin
        app = App()
        get!(app, "/items/:id::Int") do req, id; text("ok") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/items/abc"; status_exception=false)
            @test resp.status == 400
        end
    end

    @testset "ParamMismatch: fallback, catch-all, 400 page" begin
        # A later pattern that matches wins over the parse failure.
        r = Router()
        get!(r, "/users/:id::Int") do req, id; text("int $id") end
        get!(r, "/users/:name") do req, name; text("str $name") end
        c = FakeTransport(App(router = r))
        @test String(c(:get, "/users/abraham").body) == "str abraham"
        @test c(:get, "/users/7").status == 200

        # Frozen/compiled path agrees.
        freeze!(r)
        @test String(c(:get, "/users/abraham").body) == "str abraham"

        # Without a fallback: 400, and `trap(app, 400, …)` customizes it.
        app = trap(App(router = Router()), 400) do req
            json((error = "bad_param",); status = 400)
        end
        get!(app, "/users/:id::Int") do req, id; text("user $id") end
        c2 = FakeTransport(app)
        @test c2(:get, "/users/abraham").status == 400
        @test occursin("bad_param", String(c2(:get, "/users/abraham").body))

        # StaticRouter agrees: 400 without a fallback…
        sr0 = @routes begin
            get("/users/:id::Int", (req, id) -> text("user $id"))
        end
        @test FakeTransport(App(router = sr0))(:get, "/users/abraham").status == 400

        # …and a registered catch-all still serves the path.
        sr = @routes begin
            get("/users/:id::Int", (req, id) -> text("user $id"))
            get("*", req -> text("fallback"))
        end
        c3 = FakeTransport(App(router = sr))
        @test String(c3(:get, "/users/abraham").body) == "fallback"
    end
end

