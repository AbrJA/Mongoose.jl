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

