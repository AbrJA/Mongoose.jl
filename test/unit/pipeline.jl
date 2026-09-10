@testset "Standalone pipeline (no server, MongooseCore seam)" begin
    r = Router()
    get!(r, "/hi") do req; text("hello") end
    route!(r, :get, "/users/:id::Int", (req, id) -> text("user $id"))

    req = Request(:get, "/hi", Dict{String,String}(), Pair{String,String}[], "")
    ctx = Mongoose.RequestContext(r)
    res = Mongoose.invoke_request(ctx, req)
    @test res.body == "hello"

    # Typed parametric dispatch through the same seam.
    req2 = Request(:get, "/users/7", Dict{String,String}(), Pair{String,String}[], "")
    res2 = Mongoose.invoke_request(ctx, req2)
    @test res2.body == "user 7"

    # Custom error response + middleware + services all apply without a server.
    errs = Dict{Int,Union{Response,Function}}(404 => req -> Response(404, Pair{String,String}[], "custom 404"))
    svcs = (db="pool",)
    mws = Mongoose.AbstractMiddleware[logger(threshold=0, output=devnull)]
    ctx2 = Mongoose.RequestContext(r; middlewares=mws, errors=errs, services=svcs)
    res3 = Mongoose.invoke_request(ctx2,
        Request(:get, "/nope", Dict{String,String}(), Pair{String,String}[], ""))
    @test res3.status == 404
    @test res3.body == "custom 404"

    req4 = Request(:get, "/hi", Dict{String,String}(), Pair{String,String}[], "")
    ctx4 = context(req4)
    Mongoose.invoke_request(ctx2, req4)
    @test ctx4[:_services].db == "pool"
end


@testset "Auto-serialization of handler returns (format_response)" begin
    import Mongoose.MongooseCore: format_response

    @testset "Kinds" begin
        @test format_response(text("t")) == text("t")            # Response passthrough
        @test format_response("hi") isa Response
        @test format_response("hi").body == "hi"
        @test format_response("hi").status == 200
        @test get(format_response("hi").headers, "content-type", "") == "text/plain; charset=utf-8"

        b = format_response(UInt8[0x00, 0xff])
        @test b.body == UInt8[0x00, 0xff]
        @test get(b.headers, "content-type", "") == "application/octet-stream"

        d = format_response(Dict("ok" => true))
        @test get(d.headers, "content-type", "") == "application/json; charset=utf-8"

        n = format_response((a = 1, b = "x"))
        @test contains(String(n.body), "\"a\":1")

        z = format_response(nothing)
        @test z.status == 204
        @test isempty(z.body)
    end

    @testset "End-to-end via the pipeline" begin
        r = Router()
        get!(r, "/raw", req -> "raw text")
        get!(r, "/dict", req -> Dict("k" => 1))
        get!(r, "/nil", req -> nothing)
        rs = Dict{Int,Union{Response,Function}}()
        mk(p) = Request(:get, p, Dict{String,String}(), Pair{String,String}[], "")

        resp = Mongoose.invoke_request(Mongoose.RequestContext(r; errors=rs), mk("/raw"))
        @test resp.status == 200 && String(resp.body) == "raw text"
        @test get(resp.headers, "content-type", "") == "text/plain; charset=utf-8"

        resp = Mongoose.invoke_request(Mongoose.RequestContext(r; errors=rs), mk("/dict"))
        @test resp.status == 200 && contains(String(resp.body), "\"k\":1")

        resp = Mongoose.invoke_request(Mongoose.RequestContext(r; errors=rs), mk("/nil"))
        @test resp.status == 204 && isempty(resp.body)
    end

    @testset "HEAD without an explicit route is 405 (generic & frozen)" begin
        for frozen in (false, true)
            r = Router()
            get!(r, "/dict", req -> Dict("k" => 1))
            frozen && freeze!(r)
            rs = Dict{Int,Union{Response,Function}}()

            resp = Mongoose.invoke_request(Mongoose.RequestContext(r; errors=rs),
                Request(:head, "/dict", Dict{String,String}(), Pair{String,String}[], ""))
            gresp = Mongoose.invoke_request(Mongoose.RequestContext(r; errors=rs),
                Request(:get, "/dict", Dict{String,String}(), Pair{String,String}[], ""))

            # No auto-HEAD fallback: HEAD on a GET-only route is 405 and the
            # Allow header names only the methods the route serves.
            @test gresp.status == 200
            @test resp.status == 405
            @test get(resp.headers, "allow", "") == "GET"
        end
    end

    @testset "Explicit HEAD route: handler body preserved at the seam" begin
        r = Router()
        head!(r, "/ping", req -> text("pong"))
        rs = Dict{Int,Union{Response,Function}}()
        resp = Mongoose.invoke_request(Mongoose.RequestContext(r; errors=rs),
            Request(:head, "/ping", Dict{String,String}(), Pair{String,String}[], ""))
        # The seam preserves what the handler returned; the transport strips
        # HEAD bodies before they reach the wire.
        @test resp.status == 200
        @test String(resp.body) == "pong"
    end
end
