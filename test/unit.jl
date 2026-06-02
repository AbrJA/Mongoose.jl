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
    @testset "ctx! creates dict lazily" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        @test req.context === nothing
        c = ctx!(req)
        @test c isa Dict{Symbol,Any}
        @test req.context !== nothing
    end

    @testset "ctx! returns same dict" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        c1 = ctx!(req)
        c1[:key] = "value"
        c2 = ctx!(req)
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
        @test JSON.parse(result)["x"] == 1
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
