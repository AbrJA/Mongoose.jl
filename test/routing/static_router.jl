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

    @testset "Static WebSocket routes" begin
        opened = Ref(false)
        closed = Ref(false)
        router = @routes begin
            get("/hello", req -> text("hi"))
            ws("/chat", msg -> Message("Echo: $(msg.data)");
               on_open = req -> (opened[] = true; true),
               on_close = () -> (closed[] = true))
            ws("/gated", msg -> Message("gated"); allowed_origins = ["http://localhost"])
        end
        @test Mongoose.haswsroutes(router)
        @test length(router) == 1

        with_server(App(router = router)) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/chat") do ws
                HTTP.WebSockets.send(ws, "hello")
                @test String(HTTP.WebSockets.receive(ws)) == "Echo: hello"
            end
            @test opened[]

            # Origin allowlist rejects non-matching origins before upgrade.
            rejected = try
                HTTP.WebSockets.open("ws://127.0.0.1:$port/gated";
                                     headers = ["Origin" => "http://evil.example"]) do ws
                    HTTP.WebSockets.receive(ws)
                end
                false
            catch
                true
            end
            @test rejected
            sleep(0.3)
            @test closed[]
        end
    end

    @testset "Static WebSocket routes (async executor)" begin
        router = @routes begin
            ws("/chat", msg -> Message("Got: $(msg.data)"))
        end
        with_server(App(2; router = router)) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/chat") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "Got: x"
            end
        end
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

    @testset "Same path, multiple methods" begin
        router = @routes begin
            get("/items/:id::Int", (req, id) -> text("get $id"))
            put("/items/:id::Int", (req, id) -> text("put $id"))
            delete("/items/:id::Int", (req, id) -> text("del $id"))
        end
        client = FakeTransport(App(router = router))
        @test String(client(:get, "/items/7").body) == "get 7"
        @test String(client(:put, "/items/7").body) == "put 7"
        @test String(client(:delete, "/items/7").body) == "del 7"
        r = client(:patch, "/items/7")
        @test r.status == 405
        allow = get(r.headers, "allow", "")
        @test occursin("GET", allow) && occursin("PUT", allow) && occursin("DELETE", allow)
    end

    @testset "Large table (generated flat scans)" begin
        router = @routes begin
            get("/r0", req -> text("r0"))
            get("/r1", req -> text("r1"))
            get("/r2", req -> text("r2"))
            get("/r3", req -> text("r3"))
            get("/r4", req -> text("r4"))
            get("/r5", req -> text("r5"))
            get("/r6", req -> text("r6"))
            get("/r7", req -> text("r7"))
            get("/r8", req -> text("r8"))
            get("/r9", req -> text("r9"))
            get("/r10", req -> text("r10"))
            get("/r11", req -> text("r11"))
            get("/r12", req -> text("r12"))
            get("/r13", req -> text("r13"))
            get("/r14", req -> text("r14"))
            get("/r15", req -> text("r15"))
            get("/r16", req -> text("r16"))
            get("/r17", req -> text("r17"))
            get("/r18", req -> text("r18"))
            get("/r19", req -> text("r19"))
            get("/users/:id::Int", (req, id) -> json((id = id,)))
            get("/files/*path", (req, path) -> text("file:" * path))
            post("/only-post", req -> text("posted"))
            get("*", req -> text("fallback"))
        end
        @test length(router) == 24
        client = FakeTransport(App(router = router))
        @test String(client(:get, "/r0").body) == "r0"
        @test String(client(:get, "/r19").body) == "r19"
        @test occursin("\"id\":7", String(client(:get, "/users/7").body))
        @test String(client(:get, "/files/a/b.txt").body) == "file:a/b.txt"
        @test String(client(:post, "/only-post").body) == "posted"
        @test client(:get, "/only-post").status == 405
        @test client(:post, "/users/7").status == 405
        @test String(client(:get, "/nope").body) == "fallback"
    end
end
