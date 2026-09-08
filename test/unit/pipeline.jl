@testset "Standalone pipeline (no server, MongooseCore seam)" begin
    r = Router()
    get!(r, "/hi") do req; text("hello") end
    route!(r, :get, "/users/:id::Int", (req, id) -> text("user $id"))

    empty_errors = Dict{Int,Union{Response,Function}}()
    empty_services = NamedTuple()

    req = Request(:get, "/hi", Dict{String,String}(), Pair{String,String}[], "")
    res = Mongoose.invoke_request(r, Mongoose.AbstractMiddleware[], empty_errors, empty_services, req)
    @test res.body == "hello"

    # Typed parametric dispatch through the same seam.
    req2 = Request(:get, "/users/7", Dict{String,String}(), Pair{String,String}[], "")
    res2 = Mongoose.invoke_request(r, Mongoose.AbstractMiddleware[], empty_errors, empty_services, req2)
    @test res2.body == "user 7"

    # Custom error response + middleware + services all apply without a server.
    errs = Dict{Int,Union{Response,Function}}(404 => req -> Response(404, Pair{String,String}[], "custom 404"))
    svcs = (db="pool",)
    mws = Mongoose.AbstractMiddleware[logger(threshold=0, output=devnull)]
    res3 = Mongoose.invoke_request(r, mws, errs, svcs,
        Request(:get, "/nope", Dict{String,String}(), Pair{String,String}[], ""))
    @test res3.status == 404
    @test res3.body == "custom 404"

    req4 = Request(:get, "/hi", Dict{String,String}(), Pair{String,String}[], "")
    ctx4 = context(req4)
    Mongoose.invoke_request(r, mws, errs, svcs, req4)
    @test ctx4[:_services].db == "pool"
end

