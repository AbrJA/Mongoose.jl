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
    Mongoose.set_handler!(m, method, handler)
    return r
end

function Mongoose.dispatch_route(r::DictRouter, method::Symbol, path::AbstractString)
    m = get(r.routes, String(path), nothing)
    m === nothing && return nothing
    return Mongoose.RouteMatch(m, Any[])
end

function Mongoose.match_route_exact(r::DictRouter, method::Symbol, path::AbstractString)
    return Mongoose.dispatch_route(r, method, path)
end

Mongoose.has_ws_routes(::DictRouter) = false
Mongoose.route_count(r::DictRouter) = length(r.routes)

