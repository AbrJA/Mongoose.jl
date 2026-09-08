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
        Dict{Int,Union{Response,Function}}(), NamedTuple(),
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
        Dict{Int,Union{Response,Function}}(), NamedTuple(),
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
        Dict{Int,Union{Response,Function}}(), NamedTuple(),
        Request(:get, "/c", Dict{String,String}(), Pair{String,String}[], ""))
    @test res.status == 200
    @test hang == ["mw", "handler"]

    # route!(; middleware=[...]) accepts closures too.
    route!(r, :get, "/s", req -> (push!(hang, "shandler"); text("ok"));
           middleware=[(req, next) -> (push!(hang, "smw"); next())])
    @test r.fixed["/s"].handlers.get.middleware[1] isa Mongoose.FunctionMiddleware
end

