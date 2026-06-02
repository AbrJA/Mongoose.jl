# Edge case tests — comprehensive coverage for untested code paths

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

    @testset "Parameter conflict at same position" begin
        r = Router()
        route!(r, :get, "/users/:id::Int", (req, id) -> text(""))
        @test_throws RouteError route!(r, :get, "/users/:name", (req, name) -> text(""))
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
            q = get(req.query, "q", "none")
            text("q=$q")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/search?q=hello&page=1"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "q=hello"
        end
    end
end

@testset "App lifecycle edge cases" begin
    @testset "Double start is no-op" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        port = fresh_port()
        start!(s; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
            start!(s; host="127.0.0.1", port=port+1, blocking=false)  # no-op
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
        finally
            shutdown!(s)
            sleep(0.05)
        end
    end

    @testset "Double shutdown is safe" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        port = fresh_port()
        start!(s; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
        finally
            shutdown!(s)
            sleep(0.05)
            shutdown!(s)  # second shutdown should not throw
        end
    end

    @testset "BindError on port in use" begin
        s1 = App()
        s2 = App()
        get!(s1, "/") do req; text("ok") end
        get!(s2, "/") do req; text("ok") end
        port = fresh_port()
        start!(s1; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
            @test_throws BindError start!(s2; host="127.0.0.1", port=port, blocking=false)
        finally
            shutdown!(s1)
            sleep(0.05)
        end
    end

    @testset "App validation" begin
        @test_throws ServerError App(max_body=0)
        @test_throws ServerError App(max_body=-1)
        @test_throws ServerError App(poll_timeout=-1)
        @test_throws ServerError App(workers=-1)
    end

    @testset "Async App basic request" begin
        s = App(workers=2)
        get!(s, "/") do req; text("async-ok") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "async-ok"
        end
    end

    @testset "Async App concurrent requests" begin
        s = App(workers=4)
        get!(s, "/slow") do req
            sleep(0.05)
            text("done")
        end
        with_server(s) do port
            tasks = [@async HTTP.get("http://127.0.0.1:$port/slow"; status_exception=false) for _ in 1:4]
            results = [fetch(t) for t in tasks]
            @test all(r -> r.status == 200, results)
            @test all(r -> String(r.body) == "done", results)
        end
    end
end

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
end

@testset "Request features" begin
    @testset "Headers are case-insensitive" begin
        s = App()
        get!(s, "/headers") do req
            val = header(req, "x-custom-header")
            text(isnothing(val) ? "missing" : val)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/headers";
                status_exception=false,
                headers=["X-Custom-Header" => "hello"])
            @test String(resp.body) == "hello"
        end
    end

    @testset "Context per request" begin
        s = App()
        get!(s, "/ctx") do req
            c = ctx!(req)
            c[:user_id] = 42
            uid = c[:user_id]
            text("uid=$uid")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ctx"; status_exception=false)
            @test String(resp.body) == "uid=42"
        end
    end

    @testset "Query parameters parsed" begin
        s = App()
        get!(s, "/q") do req
            a = get(req.query, "a", "")
            b = get(req.query, "b", "")
            text("$a,$b")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?a=1&b=hello"; status_exception=false)
            @test String(resp.body) == "1,hello"
        end
    end
end

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
        use!(s, ratelimit(max_requests=1, window_seconds=1))

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

@testset "SSE streaming" begin
    @testset "Basic SSE response" begin
        s = App(workers=2)
        get!(s, "/events") do req
            sse(req) do writer
                emit(writer; data="hello", event="greeting")
                emit(writer; data="world", id="1")
            end
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "data: hello")
            @test contains(body, "event: greeting")
            @test contains(body, "data: world")
            @test contains(body, "id: 1")
        end
    end
end

@testset "Route groups via mount!" begin
    @testset "Basic route group" begin
        s = App()
        grp = group("/api/v1")
        get!(grp, "/users") do req; text("users") end
        post!(grp, "/users") do req; Response(201, "created") end
        get!(grp, "/health") do req; text("ok") end
        mount!(s, grp)

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v1/users"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "users"

            resp = HTTP.post("http://127.0.0.1:$port/api/v1/users"; status_exception=false, body="")
            @test resp.status == 201

            resp = HTTP.get("http://127.0.0.1:$port/api/v1/health"; status_exception=false)
            @test String(resp.body) == "ok"
        end
    end
end

@testset "provide!/inject" begin
    @testset "Service retrieved per request" begin
        s = App()
        provide!(s, :version, "1.0.0")
        get!(s, "/version") do req
            v = inject(req, :version)
            text("v=$v")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/version"; status_exception=false)
            @test String(resp.body) == "v=1.0.0"
        end
    end
end

@testset "Response format content types" begin
    s = App()
    get!(s, "/plain") do req; Response(Plain, "text") end
    get!(s, "/html") do req; Response(Html, "<h1>hi</h1>") end
    get!(s, "/json") do req; Response(Json, """{"a":1}""") end
    get!(s, "/css") do req; Response(Css, "body{}") end
    get!(s, "/js") do req; Response(Js, "var x=1") end
    get!(s, "/xml") do req; Response(Xml, "<root/>") end

    with_server(s) do port
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/plain"; status_exception=false), "Content-Type"), "text/plain")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/html"; status_exception=false), "Content-Type"), "text/html")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/json"; status_exception=false), "Content-Type"), "application/json")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/css"; status_exception=false), "Content-Type"), "text/css")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/js"; status_exception=false), "Content-Type"), "javascript")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/xml"; status_exception=false), "Content-Type"), "xml")
    end
end

@testset "WebSocket edge cases" begin
    @testset "on_close callback" begin
        closed = Ref(false)
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/close";
            on_message=msg -> Message("ack"),
            on_close=() -> (closed[] = true))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/close") do ws
                HTTP.WebSockets.send(ws, "hi")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "ack"
            end
            sleep(0.2)
            @test closed[]
        end
    end

    @testset "on_open with request info" begin
        captured_uri = Ref("")
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/open";
            on_open=req -> (captured_uri[] = req.uri; true),
            on_message=msg -> Message("ok"))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/open") do ws
                HTTP.WebSockets.send(ws, "test")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "ok"
            end
            sleep(0.1)
            @test contains(captured_uri[], "/ws/open")
        end
    end
end
