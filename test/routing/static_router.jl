@testset "StaticRouter (@routes)" begin
    @testset "Fixed, typed, wildcard, method dispatch" begin
        router = @routes begin
            get("/hello", req -> text("hi"))
            get("/users/:id::Int", (req, id) -> text("user $id"))
            get("/files/*path", (req, path) -> text("file $path"))
            post("/echo", req -> text("len=$(sizeof(body(req)))"))
        end
        @test length(router) == 4
        @test !isempty(router)
        @test isfrozen(router)
        @test freeze!(router) === router
        @test !Mongoose.haswsroutes(router)

        app = App(router = router)
        client = FakeTransport(app)

        r = client(:get, "/hello")
        @test r.status == 200
        @test String(r.body) == "hi"

        r = client(:get, "/users/42")
        @test r.status == 200
        @test String(r.body) == "user 42"

        r = client(:get, "/files/a/b.txt")
        @test r.status == 200
        @test String(r.body) == "file a/b.txt"

        r = client(:post, "/echo"; body = "hello")
        @test r.status == 200
        @test String(r.body) == "len=5"

        r = client(:get, "/nope")
        @test r.status == 404

        r = client(:put, "/hello")
        @test r.status == 405
        @test get(r.headers, "allow", "") == "GET"
    end

    @testset "Typed param mismatch falls through" begin
        router = @routes begin
            get("/users/:id::Int", (req, id) -> text("id=$id"))
            get("/users/:slug", (req, slug) -> text("slug=$slug"))
        end
        client = FakeTransport(App(router = router))
        @test String(client(:get, "/users/7").body) == "id=7"
        @test String(client(:get, "/users/bob").body) == "slug=bob"
    end

    @testset "Param decoding (RFC 3986; + stays literal)" begin
        router = @routes begin
            get("/items/:name", (req, name) -> text(name))
        end
        client = FakeTransport(App(router = router))
        @test String(client(:get, "/items/a%20b").body) == "a b"
        @test String(client(:get, "/items/a+b").body) == "a+b"
    end

    @testset "Exact beats pattern; method mask aggregates" begin
        router = @routes begin
            get("/users/:id", (req, id) -> text("pattern:$id"))
            get("/users/me", req -> text("exact"))
            post("/users/me", req -> text("posted"))
        end
        client = FakeTransport(App(router = router))
        @test String(client(:get, "/users/me").body) == "exact"
        @test String(client(:get, "/users/7").body) == "pattern:7"
        r = client(:put, "/users/me")
        @test r.status == 405
        @test get(r.headers, "allow", "") == "GET, POST"
    end

    @testset "Pattern order: first match wins" begin
        router = @routes begin
            get("/a/:x", (req, x) -> text("first:$x"))
            get("/a/:y", (req, y) -> text("second:$y"))
        end
        client = FakeTransport(App(router = router))
        @test String(client(:get, "/a/z").body) == "first:z"
    end

    @testset "Bare * catch-all is the final fallback" begin
        router = @routes begin
            get("/hello", req -> text("hi"))
            get("*", req -> text("fallback"))
        end
        client = FakeTransport(App(router = router))
        @test String(client(:get, "/hello").body) == "hi"
        @test String(client(:get, "/anything/else").body) == "fallback"
        r = client(:post, "/anything")            # catch-all is GET-only
        @test r.status == 405
        @test get(r.headers, "allow", "") == "GET"
    end

    @testset "Route-scoped middleware" begin
        router = @routes begin
            get("/open", req -> text("open"))
            get("/closed", req -> text("closed"); middleware = (security(),))
        end
        client = FakeTransport(App(router = router))
        @test get(client(:get, "/open").headers, "x-content-type-options", "") == ""
        @test get(client(:get, "/closed").headers, "x-content-type-options", "") == "nosniff"
    end

    @testset "Global middleware wraps 404/405 too" begin
        router = @routes begin
            get("/x", req -> text("x"))
        end
        app = use(App(router = router), security())
        client = FakeTransport(app)
        @test get(client(:get, "/missing").headers, "x-content-type-options", "") == "nosniff"
        @test get(client(:put, "/x").headers, "x-content-type-options", "") == "nosniff"
    end

    @testset "hasroute / matchroute protocol" begin
        router = @routes begin
            get("/hello", req -> text("hi"))
            get("/users/:id::Int", (req, id) -> text("u"))
            get("*", req -> text("fallback"))
        end
        @test Mongoose.hasroute(router, "/hello")
        @test Mongoose.hasroute(router, "/users/1")
        @test !Mongoose.hasroute(router, "/users/x")       # typed parse fails
        @test !Mongoose.hasroute(router, "/other")         # catch-all excluded

        plain = @routes begin
            get("/hello", req -> text("hi"))
            get("/users/:id::Int", (req, id) -> text("u"))
        end
        m = Mongoose.matchroute(plain, :get, "/users/5")
        @test m isa Mongoose.Matched
        @test m.params == (5,)
        @test Mongoose.matchroute(plain, :get, "/nope") isa Mongoose.NoMatch
        @test Mongoose.matchroute(plain, :put, "/hello") isa Mongoose.MethodMismatch
        @test Mongoose.matchroute(plain, :put, "/hello").allowed == 0x01
    end

    @testset "Registration is closed; WS unsupported" begin
        router = @routes begin
            get("/hello", req -> text("hi"))
        end
        @test_throws Mongoose.RouteError route!(router, :post, "/x", req -> text("x"))
        @test_throws Mongoose.RouteError ws!(router, "/ws"; on_message = req -> nothing)
        @test_throws Mongoose.RouteError get!(App(router = router), "/late", req -> text("x"))
    end

    @testset "Errors and exceptions flow through the static path" begin
        router = @routes begin
            get("/bad", req -> throw(BadRequestError("nope")))
            get("/crash", req -> error("boom"))
        end
        app = trap(App(router = router), 404) do req
            text("custom 404"; status = 404)
        end
        client = FakeTransport(app)
        @test client(:get, "/bad").status == 400
        @test client(:get, "/crash").status == 500
        r = client(:get, "/missing")
        @test r.status == 404
        @test String(r.body) == "custom 404"
    end

    @testset "Compile-time groups" begin
        router = @routes begin
            group("/api"; middleware=(cors(origins="*"),)) do api
                get("/items", req -> text("items"))
                get("/scoped", req -> text("scoped"); middleware=(etag(),))
                group("/admin"; middleware=(security(),)) do admin
                    get("/x", req -> text("admin"))
                end
            end
        end
        @test length(router) == 3
        client = FakeTransport(App(router = router))
        origin = ["Origin" => "http://example.com"]

        r = client(:get, "/api/items"; headers = origin)
        @test r.status == 200 && String(r.body) == "items"
        @test get(r.headers, "access-control-allow-origin", "") == "*"

        r = client(:get, "/api/scoped"; headers = origin)
        @test get(r.headers, "etag", "") != ""
        @test get(r.headers, "access-control-allow-origin", "") == "*"

        r = client(:get, "/api/admin/x"; headers = origin)
        @test r.status == 200 && String(r.body) == "admin"
        @test get(r.headers, "x-content-type-options", "") == "nosniff"
        @test get(r.headers, "access-control-allow-origin", "") == "*"

        # Only the prefixed paths exist.
        @test client(:get, "/items").status == 404
        @test client(:get, "/api").status == 404
    end

    @testset "Macro rejects malformed declarations" begin
        @test_throws LoadError @eval @routes begin
            get("/x")
        end
        @test_throws LoadError @eval @routes begin
            get("/a/*rest/b", req -> text("x"))
        end
        @test_throws LoadError @eval @routes begin
            fetch("/x", req -> text("x"))
        end
        @test_throws LoadError @eval @routes begin
            group("/api"; nope=1) do g
                get("/x", req -> text("x"))
            end
        end
    end

    @testset "Live server" begin
        router = @routes begin
            get("/ping", req -> text("pong"))
            get("/n/:id::Int", (req, id) -> json((id = id,)))
        end
        app = App(router = router)
        with_server(app) do port
            r = HTTP.get("http://127.0.0.1:$port/ping"; status_exception = false, retry = false)
            @test r.status == 200
            @test String(r.body) == "pong"
            r = HTTP.get("http://127.0.0.1:$port/n/3"; status_exception = false, retry = false)
            @test JSON.parse(String(r.body))["id"] == 3
            r = HTTP.get("http://127.0.0.1:$port/missing"; status_exception = false, retry = false)
            @test r.status == 404
        end
    end
end
