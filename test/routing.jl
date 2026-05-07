@testset "Typed Route Parameters" begin
    router = Router()
    route!(router, :get, "/users/:id::Int", (req, id) -> begin
        Response("User $(id) type=$(typeof(id))")
    end)
    route!(router, :get, "/score/:val::Float64", (req, val) -> begin
        Response("Score $(val) type=$(typeof(val))")
    end)
    route!(router, :get, "/greet/:name", (req, name) -> begin
        Response("Hello $(name) type=$(typeof(name))")
    end)

    server = Async(router; nworkers=1)
    start!(server, port=8100, blocking=false)
    wait_for_server("http://localhost:8100/")

    try
        response = HTTP.get("http://localhost:8100/users/42")
        @test response.status == 200
        @test String(response.body) == "User 42 type=Int64"

        response = HTTP.get("http://localhost:8100/score/3.14")
        @test response.status == 200
        @test String(response.body) == "Score 3.14 type=Float64"

        response = HTTP.get("http://localhost:8100/greet/World")
        @test response.status == 200
        @test String(response.body) == "Hello World type=String"

        response = HTTP.get("http://localhost:8100/users/abc"; status_exception=false)
        @test response.status == 404
    finally
        shutdown!(server)
    end
end

@testset "Static Router (@router)" begin
    server = Server(Routes)
    start!(server; port=8108, blocking=false)
    wait_for_server("http://localhost:8108/")

    try
        resp = HTTP.get("http://localhost:8108/hello")
        @test resp.status == 200
        @test String(resp.body) == "Hello Static"

        resp = HTTP.get("http://localhost:8108/user/123")
        @test resp.status == 200
        @test String(resp.body) == "User 123"

        HTTP.WebSockets.open("ws://localhost:8108/chat") do ws
            HTTP.WebSockets.send(ws, "ping")
            @test String(HTTP.WebSockets.receive(ws)) == "Echo: ping"
        end
    finally
        shutdown!(server)
    end
end

@testset "route! on Router" begin
    router = Router()
    ret = route!(router, :get, "/test", (req) -> Response(200, "", "ok"))
    @test ret === router  # returns the router for chaining

    matched = Mongoose._matchroute(router, :get, "/test")
    @test matched !== nothing
end

@testset "Query String Stripping" begin
    router = Router()
    route!(router, :get, "/search", (req) -> Response(200, "", "found"))
    route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", "user $id"))

    server = Server(router)
    start!(server; port=8112, blocking=false)
    wait_for_server("http://localhost:8112/")

    try
        resp = HTTP.get("http://localhost:8112/search?q=hello&page=1")
        @test resp.status == 200
        @test String(resp.body) == "found"

        resp = HTTP.get("http://localhost:8112/users/42?expand=true")
        @test resp.status == 200
        @test String(resp.body) == "user 42"
    finally
        shutdown!(server)
    end
end

@testset "HEAD Auto from GET" begin
    router = Router()
    route!(router, :get, "/page", (req) -> Response(200, "X-Custom: yes\r\n", "body content"))

    server = Server(router)
    start!(server; port=8113, blocking=false)
    wait_for_server("http://localhost:8113/")

    try
        resp = HTTP.head("http://localhost:8113/page")
        @test resp.status == 200
        @test isempty(resp.body)
        @test HTTP.header(resp, "X-Custom") == "yes"
    finally
        shutdown!(server)
    end
end

@testset "String Method Route" begin
    server = Server(Router())
    route!(server, "GET", "/a", (req) -> Response(200, "", "from get"))
    route!(server, "POST", "/a", (req) -> Response(200, "", "from post"))
    start!(server; port=8115, blocking=false)
    wait_for_server("http://localhost:8115/")

    try
        resp = HTTP.get("http://localhost:8115/a")
        @test resp.status == 200
        @test String(resp.body) == "from get"

        resp = HTTP.post("http://localhost:8115/a")
        @test resp.status == 200
        @test String(resp.body) == "from post"
    finally
        shutdown!(server)
    end
end

@testset "RouteError on Invalid Method" begin
    router = Router()
    @test_throws RouteError route!(router, :connect, "/path", (req) -> Response(200, "", ""))
    @test_throws RouteError route!(router, :trace, "/path", (req) -> Response(200, "", ""))
end

@testset "RouteError on Param Type Conflict" begin
    router = Router()
    route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
    @test_throws RouteError route!(router, :post, "/users/:id::String", (req, id) -> Response(200, "", ""))
end

@testset "URL Percent-Decode" begin
    d = Mongoose._query2dict("q=hello%20world&msg=100%25+done")
    @test d["q"] == "hello world"
    @test d["msg"] == "100% done"

    d2 = Mongoose._query2dict("q=%ZZtest&msg=ok")
    @test d2["q"] == "%ZZtest"
    @test d2["msg"] == "ok"
end

@testset "HTTP Methods: PUT PATCH DELETE OPTIONS" begin
    router = Router()
    route!(router, :put,     "/item", req -> Response(200, "", "put"))
    route!(router, :patch,   "/item", req -> Response(200, "", "patch"))
    route!(router, :delete,  "/item", req -> Response(204, "", ""))
    route!(router, :options, "/item", req -> Response(200, "Allow: GET, OPTIONS\r\n", ""))

    server = Async(router; nworkers=1)
    start!(server; port=8200, blocking=false)
    wait_for_server("http://localhost:8200/")

    try
        resp = HTTP.put("http://localhost:8200/item")
        @test resp.status == 200
        @test String(resp.body) == "put"

        resp = HTTP.patch("http://localhost:8200/item")
        @test resp.status == 200
        @test String(resp.body) == "patch"

        resp = HTTP.delete("http://localhost:8200/item")
        @test resp.status == 204

        resp = HTTP.request("OPTIONS", "http://localhost:8200/item")
        @test resp.status == 200
        @test HTTP.header(resp, "Allow") == "GET, OPTIONS"
    finally
        shutdown!(server)
    end
end

@testset "Multi-parameter route /users/:uid::Int/posts/:pid::Int" begin
    router = Router()
    route!(router, :get, "/users/:uid::Int/posts/:pid::Int",
           (req, uid, pid) -> Response(200, "", "uid=$uid pid=$pid"))

    server = Async(router; nworkers=1)
    start!(server; port=8201, blocking=false)
    wait_for_server("http://localhost:8201/")

    try
        resp = HTTP.get("http://localhost:8201/users/5/posts/12")
        @test resp.status == 200
        @test String(resp.body) == "uid=5 pid=12"

        resp = HTTP.get("http://localhost:8201/users/alice/posts/12"; status_exception=false)
        @test resp.status == 404

        resp = HTTP.get("http://localhost:8201/users/5/posts/nope"; status_exception=false)
        @test resp.status == 404
    finally
        shutdown!(server)
    end
end

@testset "Wildcard catch-all via * path" begin
    router = Router()
    route!(router, :get, "/known", req -> Response(200, "", "known"))
    route!(router, :get, "*",      req -> Response(Html, "<h1>Custom 404</h1>"; status=404))

    server = Server(router)
    start!(server; port=8202, blocking=false)
    wait_for_server("http://localhost:8202/")

    try
        resp = HTTP.get("http://localhost:8202/known")
        @test resp.status == 200

        resp = HTTP.get("http://localhost:8202/anything/else"; status_exception=false)
        @test resp.status == 404
        @test String(resp.body) == "<h1>Custom 404</h1>"
        hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
        @test occursin("text/html", hdrs["Content-Type"])
    finally
        shutdown!(server)
    end
end

@testset "route! on server returns server for chaining" begin
    server = Server(Router())
    ret1 = route!(server, :get,  "/a", req -> Response(200, "", "a"))
    @test ret1 === server
    ret2 = route!(server, :post, "/b", req -> Response(200, "", "b"))
    @test ret2 === server

    start!(server; port=8217, blocking=false)
    wait_for_server("http://localhost:8217/")

    try
        @test HTTP.get("http://localhost:8217/a").status == 200
        @test HTTP.post("http://localhost:8217/b").status == 200
    finally
        shutdown!(server)
    end
end

@testset "@router: unknown route returns 404 and method mismatch returns 405" begin
    server = Server(Routes)
    start!(server; port=8218, blocking=false)
    wait_for_server("http://localhost:8218/")

    try
        resp = HTTP.get("http://localhost:8218/nonexistent"; status_exception=false)
        @test resp.status == 404

        resp = HTTP.post("http://localhost:8218/hello"; status_exception=false)
        @test resp.status == 405
    finally
        shutdown!(server)
    end
end

@testset "@router: typed param :id::Int → typed dispatch and 404 on mismatch" begin
    server = Server(TypedApp)
    start!(server; port=8219, blocking=false)
    wait_for_server("http://localhost:8219/")

    try
        resp = HTTP.get("http://localhost:8219/item/42")
        @test resp.status == 200
        body42 = String(resp.body)
        @test occursin("id=42", body42)
        @test occursin("Int",   body42)

        resp = HTTP.get("http://localhost:8219/item/notanint"; status_exception=false)
        @test resp.status == 404
    finally
        shutdown!(server)
    end
end

@testset "@router with wildcard catch-all route" begin
    server = Server(WildcardApp)
    start!(server; port=8220, blocking=false)
    wait_for_server("http://localhost:8220/")

    try
        resp = HTTP.get("http://localhost:8220/known")
        @test resp.status == 200

        resp = HTTP.get("http://localhost:8220/missing/thing"; status_exception=false)
        @test resp.status == 404
        @test occursin("not found:", String(resp.body))
    finally
        shutdown!(server)
    end
end

@testset "@router auto-HEAD: HEAD on GET route returns 200 empty body" begin
    server = Server(Routes)
    start!(server; port=8228, blocking=false)
    wait_for_server("http://localhost:8228/")

    try
        resp_get = HTTP.get("http://localhost:8228/hello")
        @test resp_get.status == 200
        @test String(resp_get.body) == "Hello Static"

        resp_head = HTTP.head("http://localhost:8228/hello"; status_exception=false)
        @test resp_head.status == 200
        @test isempty(resp_head.body)
    finally
        shutdown!(server)
    end
end

@testset "Router: HEAD request on GET route returns 200 empty body" begin
    router = Router()
    route!(router, :get, "/headtest", req -> Response(Plain, "head-body"))

    server = Async(router; nworkers=1)
    start!(server; port=8229, blocking=false)
    wait_for_server("http://localhost:8229/")

    try
        resp_get = HTTP.get("http://localhost:8229/headtest")
        @test resp_get.status == 200
        @test String(resp_get.body) == "head-body"

        resp_head = HTTP.head("http://localhost:8229/headtest"; status_exception=false)
        @test resp_head.status == 200
        @test isempty(resp_head.body)
    finally
        shutdown!(server)
    end
end

@testset "Router: typed param bad value → 404" begin
    router = Router()
    route!(router, :get, "/item/:id::Int", (req, id) -> Response(Plain, "id=$id"))

    server = Async(router; nworkers=1)
    start!(server; port=8232, blocking=false)
    wait_for_server("http://localhost:8232/")

    try
        resp = HTTP.get("http://localhost:8232/item/42")
        @test resp.status == 200
        @test occursin("id=42", String(resp.body))

        resp = HTTP.get("http://localhost:8232/item/abc"; status_exception=false)
        @test resp.status == 404
    finally
        shutdown!(server)
    end
end

@testset "@router precedence: exact/typed before catch-all" begin
    server = Server(PrecedenceApp)
    start!(server; port=8235, blocking=false)
    wait_for_server("http://localhost:8235/")

    try
        resp = HTTP.get("http://localhost:8235/match/exact")
        @test resp.status == 200
        @test String(resp.body) == "exact"

        resp = HTTP.get("http://localhost:8235/match/42")
        @test resp.status == 200
        @test String(resp.body) == "typed:42"

        resp = HTTP.get("http://localhost:8235/match/abc"; status_exception=false)
        @test resp.status == 404

        resp = HTTP.get("http://localhost:8235/match/abc/def"; status_exception=false)
        @test resp.status == 404
    finally
        shutdown!(server)
    end
end

@testset "Router precedence: exact/typed before catch-all" begin
    router = Router()
    route!(router, :get, "/match/exact", req -> Response(Plain, "exact"))
    route!(router, :get, "/match/:id::Int", (req, id) -> Response(Plain, "typed:$id"))
    route!(router, :get, "*", req -> Response(404, "", "wild:" * req.uri))

    server = Async(router; nworkers=1)
    start!(server; port=8236, blocking=false)
    wait_for_server("http://localhost:8236/")

    try
        resp = HTTP.get("http://localhost:8236/match/exact")
        @test resp.status == 200
        @test String(resp.body) == "exact"

        resp = HTTP.get("http://localhost:8236/match/7")
        @test resp.status == 200
        @test String(resp.body) == "typed:7"

        resp = HTTP.get("http://localhost:8236/match/slug"; status_exception=false)
        @test resp.status == 404
        @test String(resp.body) == "wild:/match/slug"

        resp = HTTP.get("http://localhost:8236/match/slug/deep"; status_exception=false)
        @test resp.status == 404
        @test String(resp.body) == "wild:/match/slug/deep"
    finally
        shutdown!(server)
    end
end
