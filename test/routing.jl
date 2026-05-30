@testset "Router construction" begin
    r = Router()
    @test r isa Router
    @test isempty(r.fixed)
    @test isempty(r.ws_routes)
end

@testset "Route registration" begin
    @testset "Fixed routes" begin
        r = Router()
        route!(r, :get, "/", req -> Response(200, "", "root"))
        route!(r, :post, "/data", req -> Response(200, "", "posted"))
        @test haskey(r.fixed, "/")
        @test haskey(r.fixed, "/data")
    end

    @testset "All HTTP methods" begin
        r = Router()
        for method in [:get, :post, :put, :patch, :delete, :options, :head]
            route!(r, method, "/test", req -> Response(200, "", ""))
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
        route!(r, "GET", "/str", req -> Response(200, "", ""))
        @test haskey(r.fixed, "/str")
    end

    @testset "Invalid method" begin
        r = Router()
        @test_throws RouteError route!(r, :invalid, "/bad", req -> Response(200, "", ""))
    end

    @testset "Parametric routes" begin
        r = Router()
        route!(r, :get, "/users/:id::Int", (req, id) -> Response(200, "", "user $id"))
        route!(r, :get, "/posts/:slug", (req, slug) -> Response(200, "", "post $slug"))
        # These go into trie, not fixed
        @test !haskey(r.fixed, "/users/:id::Int")
    end

    @testset "Wildcard routes" begin
        r = Router()
        route!(r, :get, "/*path", (req, path) -> Response(200, "", path))
        @test !haskey(r.fixed, "/*path")
    end
end

@testset "Route dispatch (integration)" begin
    @testset "Fixed route dispatch" begin
        router = Router()
        route!(router, :get, "/hello", req -> Response(200, "", "world"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/hello"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "world"
        end
    end

    @testset "Parametric Int dispatch" begin
        router = Router()
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", "User $id type=$(typeof(id))"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/users/42"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "User 42 type=Int64"
        end
    end

    @testset "Parametric String dispatch" begin
        router = Router()
        route!(router, :get, "/posts/:slug", (req, slug) -> Response(200, "", "Post: $slug"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/posts/hello-world"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "Post: hello-world"
        end
    end

    @testset "Wildcard catch-all" begin
        router = Router()
        route!(router, :get, "/files/*path", (req, path) -> Response(200, "", "Path: $path"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/files/docs/readme.md"; status_exception=false)
            @test resp.status == 200
            @test contains(String(resp.body), "docs/readme.md")
        end
    end

    @testset "404 on unregistered route" begin
        router = Router()
        route!(router, :get, "/exists", req -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/nope"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "405 method not allowed" begin
        router = Router()
        route!(router, :get, "/only-get", req -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.request("POST", "http://127.0.0.1:$port/only-get"; status_exception=false)
            @test resp.status == 405
        end
    end

    @testset "Multiple params" begin
        router = Router()
        route!(router, :get, "/org/:org/repo/:repo", (req, org, repo) -> Response(200, "", "$org/$repo"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/org/julia/repo/mongoose"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "julia/mongoose"
        end
    end

    @testset "Invalid Int param returns 404" begin
        router = Router()
        route!(router, :get, "/items/:id::Int", (req, id) -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/items/abc"; status_exception=false)
            @test resp.status == 404
        end
    end
end

@testset "Route groups" begin
    @testset "Basic group" begin
        router = Router()
        api = group("/api/v1") do g
            route!(g, :get, "/users", req -> Response(200, "", "users list"))
            route!(g, :get, "/items", req -> Response(200, "", "items list"))
        end
        Mongoose.register_group!(router, api)

        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v1/users"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "users list"

            resp2 = HTTP.get("http://127.0.0.1:$port/api/v1/items"; status_exception=false)
            @test resp2.status == 200
            @test String(resp2.body) == "items list"
        end
    end
end

@testset "@router macro" begin
    @testset "Static route" begin
        s = Server(TestRoutes)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/hello"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "Hello Static"
        end
    end

    @testset "Static parametric route" begin
        s = Server(TestRoutes)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/user/99"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "User 99"
        end
    end

    @testset "Static wildcard route" begin
        s = Server(TestRoutes)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/file/some/deep/path.txt"; status_exception=false)
            @test resp.status == 200
            @test contains(String(resp.body), "some/deep/path.txt")
        end
    end
end

@testset "Query string handling" begin
    router = Router()
    route!(router, :get, "/search", req -> begin
        q = get(req.query, "q", "")
        Response(200, "", "query=$q")
    end)
    s = Server(router)
    with_server(s) do port
        resp = HTTP.get("http://127.0.0.1:$port/search?q=hello"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "query=hello"
    end
end
