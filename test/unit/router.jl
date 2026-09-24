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
    @test isempty(Router())
    r = Router()
    route!(r, :get, "/a", req -> text(""))
    route!(r, :get, "/b", req -> text(""))
    @test !isempty(r)
    io = IOBuffer()
    show(io, r)
    s = String(take!(io))
    @test contains(s, "Router(")
    @test contains(s, "2 routes")
end

@testset "Typed route parameters (tuples)" begin
    r = Router()
    route!(r, :get, "/u/:id::Int/:name", (req, id, name) -> text("$id/$name"))
    route!(r, :get, "/fixed", req -> text("f"))

    m = Mongoose.matchroute(r, :get, "/u/7/alice")
    @test m isa Mongoose.Matched
    @test m isa Mongoose.Matched && (m.params == (7, "alice") && m.params isa Tuple{Int,String})

    mf = Mongoose.matchroute(r, :get, "/fixed")
    @test mf isa Mongoose.Matched && mf.params == ()
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


@testset "Router freeze! (closed route table / trim profile)" begin
    r = Router()
    get!(r, "/a", req -> text("a"))

    freeze!(r)
    @test isfrozen(r) == true

    # Registration is closed; dispatch still works.
    @test_throws RouteError route!(r, :get, "/b", req -> text("b"))
    @test_throws RouteError get!(r, "/b", req -> text("b"))
    @test_throws RouteError ws!(r, "/ws"; on_message=req -> nothing)
    @test Mongoose.matchroute(r, :get, "/a") isa Mongoose.Matched

    # A frozen router keeps working through the full pipeline.
    res = Mongoose.process(Mongoose.RequestContext(r),
        Request(:get, "/a", Dict{String,String}(), Pair{String,String}[], ""))
    @test res.status == 200
    @test res.body == "a"

    # Fresh routers are open; contract fallback for custom routers.
    @test isfrozen(Router()) == false
    struct _OpenRouter <: Mongoose.AbstractRouter end
    @test isfrozen(_OpenRouter()) == false
    # `freeze!` is optional and defaults to a no-op, so `start!` can freeze
    # every router without capability checks; the router stays open.
    @test Mongoose.freeze!(_OpenRouter()) isa _OpenRouter
    @test isfrozen(_OpenRouter()) == false
end

@testset "Typed endpoints" begin
    f = req -> text("ok")
    ep = Mongoose.Endpoint(f)
    @test ep isa Mongoose.Endpoint{typeof(f)}   # handler type captured
    @test ep.handler === f

    r = Router()
    route!(r, :get, "/typed", f)
    @test Mongoose.gethandler(r.fixed["/typed"].handlers, :get) === f
end
