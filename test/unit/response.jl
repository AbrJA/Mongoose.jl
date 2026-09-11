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

    @testset "contenttypepair" begin
        p = Mongoose.contenttypepair(Plain)
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

@testset "statusreason" begin
    @test Mongoose.statusreason(200) == "OK"
    @test Mongoose.statusreason(201) == "Created"
    @test Mongoose.statusreason(204) == "No Content"
    @test Mongoose.statusreason(301) == "Moved Permanently"
    @test Mongoose.statusreason(400) == "Bad Request"
    @test Mongoose.statusreason(401) == "Unauthorized"
    @test Mongoose.statusreason(403) == "Forbidden"
    @test Mongoose.statusreason(404) == "Not Found"
    @test Mongoose.statusreason(405) == "Method Not Allowed"
    @test Mongoose.statusreason(429) == "Too Many Requests"
    @test Mongoose.statusreason(500) == "Internal Server Error"
    @test Mongoose.statusreason(503) == "Service Unavailable"
    @test Mongoose.statusreason(999) == ""
end

