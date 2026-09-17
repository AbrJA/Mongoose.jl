@testset "Query string handling" begin
    app = App()
    get!(app, "/search") do req
        q = get(req.query, "q", "")
        text("query=$q")
    end
    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/search?q=hello"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "query=hello"
    end
end

# --- Pluggable router: a minimal AbstractRouter implementation ---

struct DictRouter <: AbstractRouter
    routes::Dict{String,Mongoose.MethodMap}
end
DictRouter() = DictRouter(Dict{String,Mongoose.MethodMap}())

function Mongoose.route!(r::DictRouter, method::Symbol, path::AbstractString, @nospecialize(handler::Function);
                         middleware::Vector{<:Mongoose.AbstractMiddleware}=Mongoose.AbstractMiddleware[],
                         metadata=nothing)
    m = get!(() -> Mongoose.MethodMap(), r.routes, String(path))
    Mongoose.sethandler!(m, method, handler)
    return r
end

function Mongoose.matchroute(r::DictRouter, method::Symbol, path::AbstractString)
    m = get(r.routes, String(path), nothing)
    m === nothing && return Mongoose.NoMatch()
    ep = Mongoose.getendpoint(m, method)
    ep === nothing && return Mongoose.NotAllowed(Mongoose.method_bitmask(m))
    return Mongoose.Matched(ep, m, ())
end

function Mongoose.hasroute(r::DictRouter, path::AbstractString)
    return haskey(r.routes, String(Mongoose.stripquery(path)))
end

Mongoose.haswsroutes(::DictRouter) = false
Mongoose.length(r::DictRouter) = length(r.routes)

