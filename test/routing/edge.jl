@testset "Router edge cases" begin
    @testset "Float64 typed parameter" begin
        s = App()
        get!(s, "/temp/:val::Float64") do req, val; text("temp=$val") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/temp/36.6"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "temp=36.6"
        end
    end

    @testset "Bool typed parameter" begin
        s = App()
        get!(s, "/flag/:v::Bool") do req, v; text("flag=$v") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/flag/true"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "flag=true"

            resp = HTTP.get("http://127.0.0.1:$port/flag/false"; status_exception=false)
            @test String(resp.body) == "flag=false"

            resp = HTTP.get("http://127.0.0.1:$port/flag/maybe"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "UInt typed parameter" begin
        s = App()
        get!(s, "/id/:n::UInt") do req, n; text("id=$n") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/id/42"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "id=42"

            resp = HTTP.get("http://127.0.0.1:$port/id/-1"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "Deeply nested path" begin
        s = App()
        get!(s, "/a/b/c/d/e/f") do req; text("deep") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/a/b/c/d/e/f"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "deep"
        end
    end

    @testset "Deeply nested parametric path" begin
        s = App()
        get!(s, "/api/:v/users/:uid::Int/posts/:pid::Int") do req, v, uid, pid
            text("$v:$uid:$pid")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v2/users/5/posts/10"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "v2:5:10"
        end
    end

    @testset "Wildcard catch-all captures remainder" begin
        s = App()
        get!(s, "/files/*path") do req, path; text("path=$path") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/files/a/b/c.txt"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "path=a/b/c.txt"
        end
    end

    @testset "Bare wildcard catch-all" begin
        s = App()
        get!(s, "/known") do req; text("known") end
        get!(s, "*") do req; text("catch-all") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/known"; status_exception=false)
            @test String(resp.body) == "known"
            resp = HTTP.get("http://127.0.0.1:$port/anything"; status_exception=false)
            @test String(resp.body) == "catch-all"
        end
    end

    @testset "Invalid method throws RouteError" begin
        r = Router()
        @test_throws RouteError route!(r, :invalid, "/test", req -> text(""))
    end

    @testset "Overlapping parametric routes resolve in registration order" begin
        r = Router()
        route!(r, :get, "/users/:id::Int", (req, id) -> text("int:$id"))
        route!(r, :get, "/users/:name", (req, name) -> text("str:$name"))
        # Typed route wins when the segment parses; otherwise the string route.
        m1 = Mongoose.matchroute(r, :get, "/users/42")
        @test m1 !== nothing
        @test Mongoose.gethandler(m1, :get)(nothing, 42).body == "int:42"
        @test Mongoose.matchroute(r, :get, "/users/abc") isa Mongoose.Matched
        m2 = Mongoose.matchroute(r, :get, "/users/abc")
        @test m2 !== nothing
        @test Mongoose.gethandler(m2, :get)(nothing, "abc").body == "str:abc"
    end

    @testset "Static routes take precedence over parametric" begin
        r = Router()
        route!(r, :get, "/users/:name", (req, name) -> text("param:$name"))
        route!(r, :get, "/users/me", req -> text("static"))
        m = Mongoose.matchroute(r, :get, "/users/me")
        @test m !== nothing
        @test Mongoose.gethandler(m, :get)(nothing).body == "static"
    end

    @testset "All HTTP methods on App" begin
        s = App()
        for method in [:get, :post, :put, :delete, :patch, :options, :head]
            route!(s.router, method, "/method", req -> text(string(method)))
        end
        with_server(s) do port
            @test HTTP.get("http://127.0.0.1:$port/method"; status_exception=false).status == 200
            @test HTTP.post("http://127.0.0.1:$port/method"; status_exception=false, body="").status == 200
            @test HTTP.put("http://127.0.0.1:$port/method"; status_exception=false, body="").status == 200
            @test HTTP.request("DELETE", "http://127.0.0.1:$port/method"; status_exception=false).status == 200
            @test HTTP.patch("http://127.0.0.1:$port/method"; status_exception=false, body="").status == 200
            @test HTTP.request("OPTIONS", "http://127.0.0.1:$port/method"; status_exception=false).status == 200
            @test HTTP.head("http://127.0.0.1:$port/method"; status_exception=false).status == 200
        end
    end

    @testset "Query string stripped from path matching" begin
        s = App()
        get!(s, "/search") do req
            q = get(querydict(req), "q", "none")
            text("q=$q")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/search?q=hello&page=1"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "q=hello"
        end
    end
end

