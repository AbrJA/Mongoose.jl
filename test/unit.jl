@testset "Unit: _matchroute quality" begin
    r = Router()
    route!(r, :get,  "/",                  req       -> Response(200, "", "root"))
    route!(r, :get,  "/users/:id::Int",    (req, id) -> Response(200, "", "user"))
    route!(r, :post, "/items",             req       -> Response(200, "", "items"))
    route!(r, :get,  "/a/b/c",            req       -> Response(200, "", "deep-fixed"))
    route!(r, :get,  "/a/:x",             (req, x)  -> Response(200, "", "dynamic-a"))

    m = Mongoose._matchroute(r, :get, "/")
    @test m !== nothing
    @test m.params == []

    m = Mongoose._matchroute(r, :get, "/users/42")
    @test m !== nothing
    @test m.params == [42]
    @test m.params[1] isa Int

    m = Mongoose._matchroute(r, :get, "/users/7?verbose=true")
    @test m !== nothing
    @test m.params == [7]

    @test Mongoose._matchroute(r, :get, "/users/notanumber") === nothing

    m_deep = Mongoose._matchroute(r, :get, "/a/b/c")
    @test m_deep !== nothing

    m_dyn = Mongoose._matchroute(r, :get, "/a/hello")
    @test m_dyn !== nothing

    m_post_items = Mongoose._matchroute(r, :post, "/items")
    @test m_post_items !== nothing

    @test Mongoose._matchroute(r, :get, "/nonexistent/path") === nothing

    route!(r, :get, "*", req -> Response(200, "", "catchall"))
    m_wild = Mongoose._matchroute(r, :get, "/totally/unknown/path")
    @test m_wild !== nothing
end

@testset "Unit: _matchroute multi-segment typed params" begin
    r = Router()
    route!(r, :get, "/users/:uid::Int/posts/:pid::Int",
           (req, uid, pid) -> Response(200, "", "u=$uid p=$pid"))

    m = Mongoose._matchroute(r, :get, "/users/3/posts/7")
    @test m !== nothing
    @test m.params == [3, 7]
    @test m.params[1] isa Int
    @test m.params[2] isa Int

    @test Mongoose._matchroute(r, :get, "/users/abc/posts/7")  === nothing
    @test Mongoose._matchroute(r, :get, "/users/3/posts/nope") === nothing
end

@testset "Unit: _parseroute wildcard must be last segment" begin
    @test_throws ErrorException Mongoose._parseroute("/files/*name/extra")
    @test_throws ErrorException Mongoose._parseroute("/*wild/a/b")
    @test_throws ErrorException Mongoose._parseroute("/a/*mid/b")

    segs = Mongoose._parseroute("/assets/*rest")
    @test length(segs) == 2
    @test segs[end].value == "rest"
    @test segs[end].type  == String

    segs2 = Mongoose._parseroute("/a/b/:id")
    @test length(segs2) == 3
end

@testset "Unit: _sanitizeid" begin
    @test Mongoose._sanitizeid("abc-123")     == "abc-123"
    @test Mongoose._sanitizeid("")             == ""

    @test Mongoose._sanitizeid("ok\r\nevil")  == ""
    @test Mongoose._sanitizeid("id\nevil")    == ""
    @test Mongoose._sanitizeid("a\x00b")      == ""

    @test Mongoose._sanitizeid(repeat("a", 129)) == ""

    edge = repeat("x", 128)
    @test Mongoose._sanitizeid(edge) == edge
end

@testset "Unit: Response constructors" begin
    r1 = Response("hello")
    @test r1.status == 200
    @test r1.body   == "hello"
    @test occursin("text/plain", r1.headers)

    r2 = Response(Binary, UInt8[1, 2, 3])
    @test r2.body == UInt8[1, 2, 3]

    r3 = Response("created"; status=201)
    @test r3.status == 201
    @test r3.body   == "created"
    @test occursin("text/plain", r3.headers)

    r4 = Response(Xml, "<root/>")
    @test r4.status == 200
    @test occursin("application/xml", r4.headers)

    r5 = Response(Html, "<p>hi</p>"; status=201)
    @test r5.status == 201
    @test occursin("text/html", r5.headers)

    s   = SubString("hello world", 1, 5)
    r6  = Response(200, "", s)
    @test r6.body isa String
    @test r6.body == "hello"
end

@testset "Unit: _staticexists path traversal boundary" begin
    mktempdir() do base
        dir_pub  = joinpath(base, "public")
        dir_pub2 = joinpath(base, "public2")
        mkdir(dir_pub)
        mkdir(dir_pub2)
        write(joinpath(dir_pub,  "ok.txt"),     "ok")
        write(joinpath(dir_pub2, "secret.txt"), "secret")

        @test  Mongoose._staticexists(dir_pub, "/", "/ok.txt")
        @test !Mongoose._staticexists(dir_pub, "/", "/../public2/secret.txt")
        @test !Mongoose._staticexists(dir_pub, "/", "/")

        write(joinpath(dir_pub, "index.html"), "<h1>home</h1>")
        @test  Mongoose._staticexists(dir_pub, "/", "/")
    end
end

@testset "Unit: structured logger JSON format" begin
    log_buf = IOBuffer()
    lg  = logger(structured=true, output=log_buf)
    req = Request(:get, "/api/v1", Dict{String,String}(), Pair{String,String}[], "", nothing)
    lg(req, Any[], () -> Response(200, "", "ok"))
    out = String(take!(log_buf))

    @test occursin("\"method\":", out)
    @test occursin("\"GET\"",     out)
    @test occursin("\"uri\":",    out)
    @test occursin("\"/api/v1\"", out)
    @test occursin("\"status\":", out)
    @test occursin("200",         out)
    @test occursin("\"duration\":", out)
    @test occursin("\"ts\":",     out)
end

@testset "Unit: _statustext unknown code" begin
    @test Mongoose._statustext(200) == "OK"
    @test Mongoose._statustext(418) == ""
    @test Mongoose._statustext(999) == ""
    @test Mongoose._statustext(206) == "Partial Content"
    @test Mongoose._statustext(422) == "Unprocessable Entity"
end

@testset "Unit: _statustext 503" begin
    @test Mongoose._statustext(503) == "Service Unavailable"
end
