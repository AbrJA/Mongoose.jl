# Hot-path performance guards: allocation ceilings and inference checks.
#
# Ceilings are deliberately loose (~2x the measured baseline) so they survive
# Julia version differences (CI runs lts and release) while catching gross
# regressions. Tighten them alongside each optimization. Baselines and rules:
# `.opencode/skills/julia-performance/SKILL.md`.

@testset "Hot-path allocation ceilings" begin
    frozen = Router()
    route!(frozen, :get, "/", r -> text("ok"))
    route!(frozen, :get, "/users/:id::Int", (r, id) -> text("u"))
    freeze!(frozen)

    ctx = RequestContext(frozen)
    ctx_mw = RequestContext(frozen; middlewares=(cors(), etag()))
    req = Request(:get, "/", Dict{String,String}(), Pair{String,String}[], "")
    reqp = Request(:get, "/users/42", Dict{String,String}(), Pair{String,String}[], "")

    fixed() = process(ctx, req)
    param() = process(ctx, reqp)
    with_mw() = process(ctx_mw, req)
    fixed(); param(); with_mw()                 # warm up

    @test @allocated(fixed()) <= 400            # baseline ~192 B
    @test @allocated(param()) <= 1100           # baseline ~528 B
    @test @allocated(with_mw()) <= 2200         # baseline ~1088 B
end

@testset "Typed DI does not allocate a context" begin
    frozen = Router()
    route!(frozen, :get, "/", r -> text("ok"))
    freeze!(frozen)
    ctx = RequestContext(frozen; services=(db="pool",))
    req = Request(:get, "/", Dict{String,String}(), Pair{String,String}[], "")
    f() = process(ctx, req)
    f()
    # Setting the services field must not allocate a Dict{Symbol,Any} (the old
    # eager injection cost ~304 B/op).
    @test @allocated(f()) <= 400
    @test req.services.db == "pool"
    @test service(req, Val(:db)) == "pool"
end

@testset "Method token parsing" begin
    for (wire, sym) in (("GET", :get), ("POST", :post), ("PUT", :put),
                        ("DELETE", :delete), ("PATCH", :patch),
                        ("OPTIONS", :options), ("HEAD", :head))
        @test Mongoose.parse_method(Mongoose.MgStr(pointer(wire), ncodeunits(wire))) === sym
    end
    # Case-sensitive per RFC 9110 §9.1; unknown tokens are rejected.
    for wire in ("get", "Get", "BREW", "G")
        @test Mongoose.parse_method(Mongoose.MgStr(pointer(wire), ncodeunits(wire))) === :unknown
    end
    @test Mongoose.parse_method(Mongoose.MgStr(C_NULL, 0)) === :unknown
end

@testset "bytesequal" begin
    buf = Vector{UInt8}("GET")
    GC.@preserve buf begin
        p = pointer(buf)
        @test Mongoose.Kernel.bytesequal(p, 3, "GET")
        @test !Mongoose.Kernel.bytesequal(p, 3, "get")
        @test !Mongoose.Kernel.bytesequal(p, 3, "POST")
        @test !Mongoose.Kernel.bytesequal(p, 2, "GET")
    end
end

@testset "Hot helper inference" begin
    @test @inferred(Mongoose.Kernel.asheaders(("a" => "1",))) isa Headers
    @test @inferred(Mongoose.Kernel.mergeheaders(Response(200, "x"), ["A" => "1"])) isa Response
    @test @inferred(Mongoose.parse_method(Mongoose.MgStr(pointer("GET"), 3))) === :get
    @test @allocated(Mongoose.parse_method(Mongoose.MgStr(pointer("GET"), 3))) <= 16
    @test @inferred(Mongoose.Kernel.parsequery("a=1")) isa Dict{String,String}
    @test @inferred(Mongoose.statusreason(200)) isa String
    @test @inferred(Mongoose.Kernel.stripquery("/a?b=1")) isa SubString{String}
    @test @inferred(Mongoose.formatheaders(Headers(["A" => "1"]))) isa String
    @test @inferred(Mongoose.Kernel.errorstatus(NotFoundError("x"))) isa Int
end
