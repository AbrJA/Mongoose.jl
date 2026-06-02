@testset "Router construction" begin
    r = Router()
    @test r isa Router
    @test isempty(r.fixed)
    @test isempty(r.ws_routes)
end

@testset "Route registration" begin
    @testset "Fixed routes" begin
        r = Router()
        route!(r, :get, "/", req -> text("root"))
        route!(r, :post, "/data", req -> text("posted"))
        @test haskey(r.fixed, "/")
        @test haskey(r.fixed, "/data")
    end

    @testset "All HTTP methods" begin
        r = Router()
        for method in [:get, :post, :put, :patch, :delete, :options, :head]
            route!(r, method, "/test", req -> text(""))
        end
        @test r.fixed["/test"].handlers.get !== nothing
        @test r.fixed["/test"].handlers.post !== nothing
        @test r.fixed["/test"].handlers.put !== nothing
        @test r.fixed["/test"].handlers.patch !== nothing
        @test r.fixed["/test"].handlers.delete !== nothing
        @test r.fixed["/test"].handlers.options !== nothing
        @test r.fixed["/test"].handlers.head !== nothing
    end

    @testset "String method names" begin
        r = Router()
        route!(r, "GET", "/str", req -> text(""))
        @test haskey(r.fixed, "/str")
    end

    @testset "Invalid method" begin
        r = Router()
        @test_throws RouteError route!(r, :invalid, "/bad", req -> text(""))
    end

    @testset "Parametric routes" begin
        r = Router()
        route!(r, :get, "/users/:id::Int", (req, id) -> text("user $id"))
        route!(r, :get, "/posts/:slug", (req, slug) -> text("post $slug"))
        @test !haskey(r.fixed, "/users/:id::Int")
    end

    @testset "Wildcard routes" begin
        r = Router()
        route!(r, :get, "/*path", (req, path) -> text(path))
        @test !haskey(r.fixed, "/*path")
    end
end

@testset "Method helpers on App" begin
    app = App()
    get!(app, "/g") do req; text("get") end
    post!(app, "/p") do req; text("post") end
    put!(app, "/u") do req; text("put") end
    patch!(app, "/pa") do req; text("patch") end
    delete!(app, "/d") do req; text("delete") end

    with_server(app) do port
        @test HTTP.get("http://127.0.0.1:$port/g"; status_exception=false).status == 200
        @test HTTP.post("http://127.0.0.1:$port/p", []; status_exception=false).status == 200
        @test HTTP.request("PUT", "http://127.0.0.1:$port/u"; status_exception=false).status == 200
        @test HTTP.request("PATCH", "http://127.0.0.1:$port/pa"; status_exception=false).status == 200
        @test HTTP.request("DELETE", "http://127.0.0.1:$port/d"; status_exception=false).status == 200
    end
end

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

    @testset "Invalid Int param returns 404" begin
        app = App()
        get!(app, "/items/:id::Int") do req, id; text("ok") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/items/abc"; status_exception=false)
            @test resp.status == 404
        end
    end
end

@testset "Route groups" begin
    @testset "Basic group via mount!" begin
        app = App()
        grp = group("/api/v1")
        get!(grp, "/users") do req; text("users list") end
        get!(grp, "/items") do req; text("items list") end
        mount!(app, grp)

        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v1/users"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "users list"

            resp2 = HTTP.get("http://127.0.0.1:$port/api/v1/items"; status_exception=false)
            @test resp2.status == 200
            @test String(resp2.body) == "items list"
        end
    end
end

@testset "Query string handling" begin
    app = App()
    get!(app, "/search") do req
        q = get(req.query, "q", "")
        text("query=$q")
    end
    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/search?q=hello"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "query=hello"
    end
end
