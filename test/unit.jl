# Pure unit tests — no network I/O, no servers started.

@testset "Response constructors" begin
    @testset "2-arg constructor (status + body)" begin
        r = Response(200, "hello")
        @test r.status == 200
        @test r.body == "hello"
    end

    @testset "Binary body" begin
        data = UInt8[1, 2, 3, 4]
        r = Response(200, Pair{String,String}[], data)
        @test r.body == data
    end

    @testset "Format constructors" begin
        r = Response(Plain, "text")
        @test r.status == 200
        @test r.body == "text"
        @test any(p -> contains(p.second, "text/plain"), r.headers)

        r2 = Response(Html, "<p>hi</p>")
        @test any(p -> contains(p.second, "text/html"), r2.headers)

        r3 = Response(Json, """{"a":1}""")
        @test any(p -> contains(p.second, "application/json"), r3.headers)

        r4 = Response(Css, "body{}")
        @test any(p -> contains(p.second, "text/css"), r4.headers)

        r5 = Response(Js, "var x=1;")
        @test any(p -> contains(p.second, "javascript"), r5.headers)

        r6 = Response(Xml, "<root/>")
        @test any(p -> contains(p.second, "application/xml"), r6.headers)
    end

    @testset "Format with custom status" begin
        r = Response(Plain, "not found"; status=404)
        @test r.status == 404
    end

    @testset "Format with custom headers" begin
        r = Response(Plain, "ok"; headers=["X-Custom" => "val"])
        @test any(p -> p.first == "X-Custom" && p.second == "val", r.headers)
    end

    @testset "Shorthand string constructor" begin
        r = Response("hello")
        @test r.status == 200
        @test r.body == "hello"
        @test any(p -> contains(p.second, "text/plain"), r.headers)
    end

    @testset "Response helpers" begin
        @test text("hi").status == 200
        @test html("<p>").status == 200
        @test json("{\"a\":1}").status == 200
        @test redirect("/path").status == 302
        @test redirect("/path"; status=301).status == 301
        @test HTTP.header(HTTP.Response(200, redirect("/new").headers, UInt8[]), "Location") == "/new"
    end
end

@testset "Request constructors" begin
    @testset "Full constructor" begin
        req = Request(:get, "/test?q=1", "/test",
            Dict("q" => "1"),
            Headers(["content-type" => "text/plain"]),
            "")
        @test req.method == :get
        @test req.uri == "/test?q=1"
        @test req.path == "/test"
        @test req.query["q"] == "1"
        @test req.body == ""
    end

    @testset "Vector headers convenience" begin
        req = Request(:post, "/data", "/data",
            Dict{String,String}(),
            ["content-type" => "application/json"],
            """{"key":"val"}""")
        @test req.headers isa Headers
        @test get(req.headers, "content-type", "") == "application/json"
    end

    @testset "Auto-strip query" begin
        req = Request(:get, "/search?q=hello",
            Dict("q" => "hello"),
            Headers(),
            "")
        @test req.path == "/search"
    end
end

@testset "Headers" begin
    @testset "Empty headers" begin
        h = Headers()
        @test isempty(h)
        @test length(h) == 0
    end

    @testset "Get with case insensitivity" begin
        h = Headers(["content-type" => "text/html", "x-custom" => "value"])
        @test get(h, "content-type", "") == "text/html"
        @test get(h, "Content-Type", "") == "text/html"
        @test get(h, "CONTENT-TYPE", "") == "text/html"
    end

    @testset "haskey" begin
        h = Headers(["authorization" => "Bearer token"])
        @test haskey(h, "authorization")
        @test haskey(h, "Authorization")
        @test !haskey(h, "x-missing")
    end

    @testset "Default value for missing key" begin
        h = Headers(["a" => "1"])
        @test get(h, "b", "default") == "default"
    end

    @testset "Iteration" begin
        pairs = ["a" => "1", "b" => "2"]
        h = Headers(pairs)
        collected = collect(h)
        @test length(collected) == 2
    end
end

@testset "Context" begin
    @testset "context() creates dict lazily" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        @test req.context === nothing
        c = context(req)
        @test c isa Dict{Symbol,Any}
        @test req.context !== nothing
    end

    @testset "context() returns same dict" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        c1 = context(req)
        c1[:key] = "value"
        c2 = context(req)
        @test c1 === c2
        @test c2[:key] == "value"
    end
end

@testset "Cookie" begin
    @testset "Basic cookie" begin
        c = Mongoose.Cookie("name", "value")
        @test c.name == "name"
        @test c.value == "value"
        @test c.path == "/"
        @test c.httponly == true
        @test c.samesite == :lax
        @test c.max_age == -1
    end

    @testset "Cookie with options" begin
        c = Mongoose.Cookie("session", "abc"; path="/app", domain="example.com",
                   max_age=3600, secure=true, httponly=false, samesite=:strict)
        @test c.path == "/app"
        @test c.domain == "example.com"
        @test c.max_age == 3600
        @test c.secure == true
        @test c.httponly == false
        @test c.samesite == :strict
    end

    @testset "Invalid samesite" begin
        @test_throws ErrorException Mongoose.Cookie("x", "y"; samesite=:invalid)
    end

    @testset "bake/serialize" begin
        c = Mongoose.Cookie("id", "123"; max_age=600, secure=true, httponly=true, samesite=:strict)
        s = bake(c)
        @test contains(s, "id=123")
        @test contains(s, "Max-Age=600")
        @test contains(s, "Secure")
        @test contains(s, "HttpOnly")
        @test contains(s, "SameSite=Strict")
        @test contains(s, "Path=/")
    end

    @testset "bake session cookie (no max_age)" begin
        c = Mongoose.Cookie("temp", "val")
        s = bake(c)
        @test contains(s, "temp=val")
        @test !contains(s, "Max-Age")
    end
end

@testset "cookies(req)" begin
    @testset "Parse single cookie" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["cookie" => "name=value"]), "")
        jar = Mongoose.cookies(req)
        @test jar["name"] == "value"
    end

    @testset "Parse multiple cookies" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["cookie" => "a=1; b=2; c=3"]), "")
        jar = Mongoose.cookies(req)
        @test jar["a"] == "1"
        @test jar["b"] == "2"
        @test jar["c"] == "3"
    end

    @testset "No cookie header" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        jar = Mongoose.cookies(req)
        @test isempty(jar)
    end

    @testset "Empty cookie value" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["cookie" => "key="]), "")
        jar = Mongoose.cookies(req)
        @test jar["key"] == ""
    end
end

@testset "Error types" begin
    @testset "RouteError" begin
        e = RouteError("bad route")
        @test e.msg == "bad route"
        io = IOBuffer()
        showerror(io, e)
        @test contains(String(take!(io)), "RouteError")
    end

    @testset "ServerError" begin
        e = ServerError("bad config")
        @test e.msg == "bad config"
        io = IOBuffer()
        showerror(io, e)
        @test contains(String(take!(io)), "ServerError")
    end

    @testset "BindError" begin
        e = BindError("port in use")
        @test e.msg == "port in use"
        io = IOBuffer()
        showerror(io, e)
        @test contains(String(take!(io)), "BindError")
    end
end

@testset "Content format types" begin
    @testset "MIME types" begin
        @test Mongoose.mime(Plain) == "text/plain; charset=utf-8"
        @test Mongoose.mime(Html) == "text/html; charset=utf-8"
        @test Mongoose.mime(Json) == "application/json; charset=utf-8"
        @test Mongoose.mime(Css) == "text/css; charset=utf-8"
        @test Mongoose.mime(Js) == "application/javascript; charset=utf-8"
        @test Mongoose.mime(Xml) == "application/xml; charset=utf-8"
        @test Mongoose.mime(Binary) == "application/octet-stream"
    end

    @testset "content_type_pair" begin
        p = Mongoose.content_type_pair(Plain)
        @test p isa Pair{String,String}
        @test contains(p.second, "text/plain")
    end

    @testset "encode passthrough for strings" begin
        @test Mongoose.encode(Plain, "hello") == "hello"
        @test Mongoose.encode(Json, """{"a":1}""") == """{"a":1}"""
    end

    @testset "encode for Json with dict (via extension)" begin
        result = Mongoose.encode(Json, Dict("x" => 1))
        @test contains(result, "\"x\"") && contains(result, "1")
    end
end

@testset "Message type" begin
    @testset "String message" begin
        m = Message("hello")
        @test m.data == "hello"
    end

    @testset "Binary message" begin
        m = Message(UInt8[1, 2, 3])
        @test m.data == UInt8[1, 2, 3]
    end
end

@testset "StreamResponse constructors" begin
    @testset "Basic StreamResponse" begin
        sr = StreamResponse(w -> nothing, 200, "text/plain")
        @test sr.status == 200
        @test sr.content_type == "text/plain"
    end

    @testset "Default content type" begin
        sr = StreamResponse(w -> nothing)
        @test sr.content_type == "application/octet-stream"
    end

    @testset "With custom headers" begin
        sr = StreamResponse(w -> nothing, 200;
            content_type="text/event-stream",
            headers=["Cache-Control" => "no-cache"])
        @test length(sr.headers) == 1
        @test sr.headers[1] == ("Cache-Control" => "no-cache")
    end
end

@testset "RouteGroup construction" begin
    @testset "Basic group" begin
        g = group("/api/v1") do g
            route!(g, :get, "/users", req -> text(""))
            route!(g, :post, "/users", req -> text(""))
        end
        @test g.prefix == "/api/v1"
        @test length(g.routes) == 2
        @test g.routes[1][1] == :get
        @test g.routes[1][2] == "/users"
    end

    @testset "Group with middleware" begin
        mw = cors()
        g = group("/admin"; middleware=[mw]) do g
            route!(g, :get, "/panel", req -> text(""))
        end
        @test length(g.middleware) == 1
    end

    @testset "Non-block group" begin
        g = group("/prefix")
        @test g.prefix == "/prefix"
        @test isempty(g.routes)
    end
end

@testset "Router display" begin
    r = Router()
    route!(r, :get, "/a", req -> text(""))
    route!(r, :get, "/b", req -> text(""))
    io = IOBuffer()
    show(io, r)
    s = String(take!(io))
    @test contains(s, "Router(")
    @test contains(s, "2 routes")
end

@testset "status_reason" begin
    @test Mongoose.status_reason(200) == "OK"
    @test Mongoose.status_reason(201) == "Created"
    @test Mongoose.status_reason(204) == "No Content"
    @test Mongoose.status_reason(301) == "Moved Permanently"
    @test Mongoose.status_reason(400) == "Bad Request"
    @test Mongoose.status_reason(401) == "Unauthorized"
    @test Mongoose.status_reason(403) == "Forbidden"
    @test Mongoose.status_reason(404) == "Not Found"
    @test Mongoose.status_reason(405) == "Method Not Allowed"
    @test Mongoose.status_reason(429) == "Too Many Requests"
    @test Mongoose.status_reason(500) == "Internal Server Error"
    @test Mongoose.status_reason(503) == "Service Unavailable"
    @test Mongoose.status_reason(999) == ""
end

@testset "Query parameter helpers" begin
    @testset "String query param" begin
        req = Request(:get, "/search?q=hello&page=2", "/search",
            Dict("q" => "hello", "page" => "2"), Headers(), "")
        @test query(req, "q") == "hello"
        @test query(req, "missing") === nothing
        @test query(req, "q", "") == "hello"
        @test query(req, "missing", "default") == "default"
    end

    @testset "Integer query param" begin
        req = Request(:get, "/list?page=3&limit=50", "/list",
            Dict("page" => "3", "limit" => "50"), Headers(), "")
        @test query(req, "page", 1) == 3
        @test query(req, "limit", 20) == 50
        @test query(req, "offset", 0) == 0
    end

    @testset "Invalid integer returns default" begin
        req = Request(:get, "/list?page=abc", "/list",
            Dict("page" => "abc"), Headers(), "")
        @test query(req, "page", 1) == 1
    end

    @testset "Float query param" begin
        req = Request(:get, "/calc?rate=3.14", "/calc",
            Dict("rate" => "3.14"), Headers(), "")
        @test query(req, "rate", 0.0) ≈ 3.14
        @test query(req, "missing", 1.0) == 1.0
    end

    @testset "Bool query param" begin
        req = Request(:get, "/flags?debug=true&verbose=1&off=false", "/flags",
            Dict("debug" => "true", "verbose" => "1", "off" => "false"), Headers(), "")
        @test query(req, "debug", false) == true
        @test query(req, "verbose", false) == true
        @test query(req, "off", true) == false
        @test query(req, "missing", false) == false
    end
end

@testset "Body parsing helpers" begin
    @testset "body(req) returns raw body" begin
        req = Request(:post, "/data", "/data",
            Dict{String,String}(), Headers(), "raw body content")
        @test body(req) == "raw body content"
    end
end

@testset "JSON integration" begin
    @testset "json() with Dict" begin
        resp = json(Dict("key" => "value"))
        @test resp.status == 200
        @test contains(resp.body, "\"key\"")
        @test contains(resp.body, "\"value\"")
        @test any(p -> contains(p.second, "application/json"), resp.headers)
    end

    @testset "json() with NamedTuple" begin
        resp = json((id=1, name="test"))
        @test resp.status == 200
        @test contains(resp.body, "\"id\"")
        @test contains(resp.body, "\"name\"")
    end

    @testset "json() with custom status" begin
        resp = json(Dict("error" => "not found"); status=404)
        @test resp.status == 404
    end

    @testset "json(req) parses body" begin
        req = Request(:post, "/", "/",
            Dict{String,String}(),
            Headers(["content-type" => "application/json"]),
            """{"hello":"world"}""")
        data = json(req)
        @test data["hello"] == "world"
    end
end

@testset "Multipart parsing" begin
    @testset "Parse simple multipart" begin
        boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
        body_content = "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" *
            "Content-Disposition: form-data; name=\"field1\"\r\n\r\n" *
            "value1\r\n" *
            "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" *
            "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" *
            "Content-Type: text/plain\r\n\r\n" *
            "file content here\r\n" *
            "------WebKitFormBoundary7MA4YWxkTrZu0gW--"
        req = Request(:post, "/upload", "/upload",
            Dict{String,String}(),
            Headers(["content-type" => "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"]),
            body_content)
        parts = multipart(req)
        @test parts["field1"] == "value1"
        @test parts["file"] isa MultipartFile
        @test parts["file"].filename == "test.txt"
        @test parts["file"].content_type == "text/plain"
        @test String(parts["file"].data) == "file content here"
    end

    @testset "Wrong content type throws" begin
        req = Request(:post, "/upload", "/upload",
            Dict{String,String}(),
            Headers(["content-type" => "application/json"]),
            "{}")
        @test_throws ArgumentError multipart(req)
    end
end

@testset "Compression middleware (unit)" begin
    mw = compress(min_size=10)
    @test mw isa Mongoose.Compress

    @testset "Skips small responses" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["accept-encoding" => "gzip"]), "")
        handler = () -> Response(Json, "hi")  # Too small
        resp = mw(req, handler)
        @test resp.status == 200
        # Should NOT be compressed (body too small)
        @test !any(p -> p.first == "Content-Encoding", resp.headers)
    end

    @testset "Compresses large JSON" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["accept-encoding" => "gzip, deflate"]), "")
        large_body = repeat("a", 2000)
        handler = () -> Response(Json, large_body)
        resp = mw(req, handler)
        @test resp.status == 200
        @test any(p -> p.first == "Content-Encoding" && p.second == "gzip", resp.headers)
        @test resp.body isa Vector{UInt8}
    end

    @testset "Skips if no Accept-Encoding" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        large_body = repeat("x", 2000)
        handler = () -> Response(Plain, large_body)
        resp = mw(req, handler)
        @test !any(p -> p.first == "Content-Encoding", resp.headers)
    end
end

@testset "TestClient" begin
    app = App()
    get!(app, "/hello") do req
        text("Hello World")
    end
    get!(app, "/json") do req
        json((message="hi", count=42))
    end
    post!(app, "/echo") do req
        text("Got: $(req.body)")
    end
    get!(app, "/query") do req
        q = query(req, "name", "unknown")
        text("Hello $q")
    end

    client = Mongoose.TestClient(app)

    @testset "GET text response" begin
        resp = client(:get, "/hello")
        @test resp.status == 200
        @test resp.body == "Hello World"
    end

    @testset "GET JSON response" begin
        resp = client(:get, "/json")
        @test resp.status == 200
        @test contains(resp.body, "\"message\"")
        @test contains(resp.body, "\"hi\"")
    end

    @testset "POST with body" begin
        resp = client(:post, "/echo"; body="test data")
        @test resp.status == 200
        @test resp.body == "Got: test data"
    end

    @testset "Query parameters" begin
        resp = client(:get, "/query"; query=Dict("name" => "Julia"))
        @test resp.status == 200
        @test contains(resp.body, "Julia")
    end

    @testset "404 for missing route" begin
        resp = client(:get, "/nonexistent")
        @test resp.status == 404
    end

    @testset "405 for wrong method" begin
        resp = client(:post, "/hello")
        @test resp.status == 405
    end
end

@testset "Typed route parameters (tuples)" begin
    r = Router()
    route!(r, :get, "/u/:id::Int/:name", (req, id, name) -> text("$id/$name"))
    route!(r, :get, "/fixed", req -> text("f"))

    m = Mongoose.dispatch_route(r, :get, "/u/7/alice")
    @test m === nothing ? false : (m.params == (7, "alice") && m.params isa Tuple{Int,String})

    mf = Mongoose.dispatch_route(r, :get, "/fixed")
    @test mf !== nothing && mf.params == ()
end

# Middleware that records its phase into a shared sink.
struct _RecordMw <: Mongoose.AbstractMiddleware
    label::String
    sink::Vector{String}
end
function (mw::_RecordMw)(req::Request, next::Function)
    push!(mw.sink, mw.label)
    response = next()
    push!(mw.sink, string(mw.label, ":after"))
    return response
end

@testset "Scoped middleware as route metadata (Endpoint)" begin
    r = Router()
    sink = String[]

    route!(r, :get, "/s", req -> (push!(sink, "handler"); text("ok"));
           middleware=[_RecordMw("route", sink)], metadata=:docs)

    ep = r.fixed["/s"].handlers.get
    @test ep isa Mongoose.Endpoint
    @test length(ep.middleware) == 1
    @test ep.metadata === :docs

    # Global ball then route-scoped middleware compose: g → route → handler.
    global_mw = _RecordMw("global", sink)
    res = Mongoose.invoke_request(r, [_RecordMw("global", sink)],
        Dict{Int,Union{Response,Function}}(), Dict{Symbol,Any}(),
        Request(:get, "/s", Dict{String,String}(), Pair{String,String}[], ""))
    @test res.status == 200
    @test sink == ["global", "route", "handler", "route:after", "global:after"]
end

@testset "Group middleware is metadata, not closures" begin
    r = Router()
    sink = String[]
    grp = group("/api", middleware=[_RecordMw("grp", sink)])
    get!(grp, "/x") do req; push!(sink, "handler"); text("ok") end
    mount!(r, grp)

    ep = r.fixed["/api/x"].handlers.get
    @test ep isa Mongoose.Endpoint
    @test length(ep.middleware) == 1
    @test ep.middleware[1].label == "grp"

    res = Mongoose.invoke_request(r, Mongoose.AbstractMiddleware[],
        Dict{Int,Union{Response,Function}}(), Dict{Symbol,Any}(),
        Request(:get, "/api/x", Dict{String,String}(), Pair{String,String}[], ""))
    @test res.status == 200
    @test sink == ["grp", "handler", "grp:after"]
end

@testset "Plain callable middleware (no subtype needed)" begin
    r = Router()
    hang = String[]
    get!(r, "/c", req -> (push!(hang, "handler"); text("ok")))

    # use! accepts a plain closure.
    app = App()
    use!(app) do req, next
        push!(hang, "mw")
        next()
    end
    @test app.middlewares[1] isa Mongoose.FunctionMiddleware

    res = Mongoose.invoke_request(r, app.middlewares,
        Dict{Int,Union{Response,Function}}(), Dict{Symbol,Any}(),
        Request(:get, "/c", Dict{String,String}(), Pair{String,String}[], ""))
    @test res.status == 200
    @test hang == ["mw", "handler"]

    # route!(; middleware=[...]) accepts closures too.
    route!(r, :get, "/s", req -> (push!(hang, "shandler"); text("ok"));
           middleware=[(req, next) -> (push!(hang, "smw"); next())])
    @test r.fixed["/s"].handlers.get.middleware[1] isa Mongoose.FunctionMiddleware
end

@testset "Standalone pipeline (no server, MongooseCore seam)" begin
    r = Router()
    get!(r, "/hi") do req; text("hello") end
    route!(r, :get, "/users/:id::Int", (req, id) -> text("user $id"))

    empty_errors = Dict{Int,Union{Response,Function}}()
    empty_services = Dict{Symbol,Any}()

    req = Request(:get, "/hi", Dict{String,String}(), Pair{String,String}[], "")
    res = Mongoose.invoke_request(r, Mongoose.AbstractMiddleware[], empty_errors, empty_services, req)
    @test res.body == "hello"

    # Typed parametric dispatch through the same seam.
    req2 = Request(:get, "/users/7", Dict{String,String}(), Pair{String,String}[], "")
    res2 = Mongoose.invoke_request(r, Mongoose.AbstractMiddleware[], empty_errors, empty_services, req2)
    @test res2.body == "user 7"

    # Custom error response + middleware + services all apply without a server.
    errs = Dict{Int,Union{Response,Function}}(404 => req -> Response(404, Pair{String,String}[], "custom 404"))
    svcs = Dict{Symbol,Any}(:db => "pool")
    mws = Mongoose.AbstractMiddleware[logger(threshold=0, output=devnull)]
    res3 = Mongoose.invoke_request(r, mws, errs, svcs,
        Request(:get, "/nope", Dict{String,String}(), Pair{String,String}[], ""))
    @test res3.status == 404
    @test res3.body == "custom 404"

    req4 = Request(:get, "/hi", Dict{String,String}(), Pair{String,String}[], "")
    ctx4 = context(req4)
    Mongoose.invoke_request(r, mws, errs, svcs, req4)
    @test ctx4[:_services][:db] == "pool"
end

@testset "Executor contract" begin
    # SyncExecutor runs jobs inline.
    s = SyncExecutor()
    @test submit!(s, () -> 42) == 42
    @test has_pending(s) == false

    # Missing capabilities fail loudly.
    struct _NoExec <: Mongoose.AbstractExecutor end
    @test_throws MethodError submit!(_NoExec(), () -> 1)
    @test_throws MethodError stop!(_NoExec())
end

@testset "Transport capability traits + FakeTransport (FFI-free)" begin
    # Router capability via the trait spelling.
    r = Router()
    @test Mongoose.supports_websocket(r) == false
    ws!(r, "/ws"; on_message=req -> nothing)
    @test Mongoose.supports_websocket(r) == true

    # A full request cycle with a fake transport, no server started.
    app = App()
    get!(app, "/hi") do req
        json((msg = "hi",))
    end
    use!(app, cors())

    client = FakeTransport(app)
    @test client isa AbstractTransport
    @test Mongoose.supports_websocket(client) == false
    @test Mongoose.supports_tls(client) == false
    @test Mongoose.supports_streaming(client) == true

    resp = client(:get, "/hi")
    @test resp.status == 200
    @test contains(String(resp.body), "hi")
    @test app.running[] == false  # never started the C server

    # TestClient is the same fake transport (compat alias).
    @test Mongoose.TestClient === FakeTransport
end
