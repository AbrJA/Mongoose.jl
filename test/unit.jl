# Pure unit tests — no network I/O, no servers started.

@testset "Response constructors" begin
    @testset "Raw constructor" begin
        r = Response(200, "", "hello")
        @test r.status == 200
        @test r.headers == ""
        @test r.body == "hello"
    end

    @testset "Raw with headers" begin
        r = Response(201, "Content-Type: text/plain\r\n", "created")
        @test r.status == 201
        @test contains(r.headers, "Content-Type")
    end

    @testset "Binary body" begin
        data = UInt8[1, 2, 3, 4]
        r = Response(200, "", data)
        @test r.body == data
    end

    @testset "Format constructors" begin
        r = Response(Plain, "text")
        @test r.status == 200
        @test r.body == "text"
        @test contains(r.headers, "text/plain")

        r2 = Response(Html, "<p>hi</p>")
        @test contains(r2.headers, "text/html")

        r3 = Response(Json, """{"a":1}""")
        @test contains(r3.headers, "application/json")

        r4 = Response(Css, "body{}")
        @test contains(r4.headers, "text/css")

        r5 = Response(Js, "var x=1;")
        @test contains(r5.headers, "javascript")

        r6 = Response(Xml, "<root/>")
        @test contains(r6.headers, "application/xml")
    end

    @testset "Format with custom status" begin
        r = Response(Plain, "not found"; status=404)
        @test r.status == 404
    end

    @testset "Format with custom headers" begin
        r = Response(Plain, "ok"; headers=["X-Custom" => "val"])
        @test contains(r.headers, "X-Custom: val")
    end

    @testset "Shorthand string constructor" begin
        r = Response("hello")
        @test r.status == 200
        @test r.body == "hello"
        @test contains(r.headers, "text/plain")
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
    @testset "context! creates dict lazily" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        @test req.context === nothing
        ctx = context!(req)
        @test ctx isa Dict{Symbol,Any}
        @test req.context !== nothing
    end

    @testset "context! returns same dict" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        ctx1 = context!(req)
        ctx1[:key] = "value"
        ctx2 = context!(req)
        @test ctx1 === ctx2
        @test ctx2[:key] == "value"
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

    @testset "serialize_cookie" begin
        c = Mongoose.Cookie("id", "123"; max_age=600, secure=true, httponly=true, samesite=:strict)
        s = serialize_cookie(c)
        @test contains(s, "id=123")
        @test contains(s, "Max-Age=600")
        @test contains(s, "Secure")
        @test contains(s, "HttpOnly")
        @test contains(s, "SameSite=Strict")
        @test contains(s, "Path=/")
    end

    @testset "serialize_cookie session (no max_age)" begin
        c = Mongoose.Cookie("temp", "val")
        s = serialize_cookie(c)
        @test contains(s, "temp=val")
        @test !contains(s, "Max-Age")
    end
end

@testset "parse_cookies" begin
    @testset "Parse single cookie" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["cookie" => "name=value"]), "")
        cookies = parse_cookies(req)
        @test cookies["name"] == "value"
    end

    @testset "Parse multiple cookies" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["cookie" => "a=1; b=2; c=3"]), "")
        cookies = parse_cookies(req)
        @test cookies["a"] == "1"
        @test cookies["b"] == "2"
        @test cookies["c"] == "3"
    end

    @testset "No cookie header" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        cookies = parse_cookies(req)
        @test isempty(cookies)
    end

    @testset "Empty cookie value" begin
        req = Request(:get, "/", "/", Dict{String,String}(),
            Headers(["cookie" => "key="]), "")
        cookies = parse_cookies(req)
        @test cookies["key"] == ""
    end
end

@testset "ServiceRegistry" begin
    @testset "Register and retrieve factory" begin
        reg = ServiceRegistry()
        register!(reg, :db, () -> "postgres://localhost")
        @test service(reg, :db) == "postgres://localhost"
    end

    @testset "Factory called once (lazy singleton)" begin
        count = Ref(0)
        reg = ServiceRegistry()
        register!(reg, :counter, () -> (count[] += 1; count[]))
        @test service(reg, :counter) == 1
        @test service(reg, :counter) == 1  # Same value, factory not called again
        @test count[] == 1
    end

    @testset "Register direct instance" begin
        reg = ServiceRegistry()
        register!(reg, :config, Dict("env" => "test"))
        @test service(reg, :config)["env"] == "test"
    end

    @testset "Missing service throws" begin
        reg = ServiceRegistry()
        @test_throws ErrorException service(reg, :nonexistent)
    end

    @testset "Multiple services" begin
        reg = ServiceRegistry()
        register!(reg, :a, () -> "service_a")
        register!(reg, :b, () -> "service_b")
        @test service(reg, :a) == "service_a"
        @test service(reg, :b) == "service_b"
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

    @testset "Content-Type headers" begin
        @test contains(Mongoose.content_type_header(Plain), "text/plain")
        @test contains(Mongoose.content_type_header(Json), "application/json")
    end

    @testset "encode passthrough for strings" begin
        @test Mongoose.encode(Plain, "hello") == "hello"
        @test Mongoose.encode(Json, """{"a":1}""") == """{"a":1}"""
    end

    @testset "encode for Json with dict (via extension)" begin
        result = Mongoose.encode(Json, Dict("x" => 1))
        @test JSON.parse(result)["x"] == 1
    end
end

@testset "Config" begin
    @testset "Default config" begin
        c = Config()
        @test c.poll_timeout == 1
        @test c.nworkers == 4
        @test c.nqueue == 1024
        @test c.request_timeout == 0
        @test c.ws_idle_timeout == 0
    end

    @testset "Custom config" begin
        c = Config(nworkers=8, nqueue=2048, max_body=4096)
        @test c.nworkers == 8
        @test c.nqueue == 2048
        @test c.max_body == 4096
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
        sr = StreamResponse(w -> nothing, 200; content_type="text/plain")
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
            route!(g, :get, "/users", req -> Response(200, "", ""))
            route!(g, :post, "/users", req -> Response(201, "", ""))
        end
        @test g.prefix == "/api/v1"
        @test length(g.routes) == 2
        @test g.routes[1][1] == :get
        @test g.routes[1][2] == "/users"
    end

    @testset "Group with middleware" begin
        mw = cors()
        g = group("/admin"; middleware=[mw]) do g
            route!(g, :get, "/panel", req -> Response(200, "", ""))
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
    route!(r, :get, "/a", req -> Response(200, "", ""))
    route!(r, :get, "/b", req -> Response(200, "", ""))
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
