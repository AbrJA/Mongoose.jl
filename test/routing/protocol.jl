@testset "Router protocol (contract-by-fallback)" begin
    struct _FallbackRouter <: AbstractRouter end

    r = _FallbackRouter()
    # Optional capabilities default to "not supported".
    @test Mongoose.has_ws_routes(r) == false
    @test Mongoose.ws_endpoint(r, "/ws") === nothing
    @test Mongoose.route_count(r) == 0
    # Required protocol throws a clear MethodError when unimplemented.
    @test_throws MethodError Mongoose.match_route(r, :get, "/")
    @test_throws MethodError Mongoose.match_route_exact(r, :get, "/")
    @test_throws MethodError route!(r, :get, "/x", req -> text(""))
    @test_throws MethodError ws!(r, "/x"; on_message=req -> nothing)
end

@testset "RegexRouter alternative (pluggability showcase)" begin
    # A tiny regex-based router implementing the AbstractRouter contract.
    struct RegexRouter <: AbstractRouter
        entries::Vector{Tuple{Regex,Symbol,Mongoose.Endpoint}}
    end
    RegexRouter() = RegexRouter(Tuple{Regex,Symbol,Mongoose.Endpoint}[])

    function Mongoose.route!(r::RegexRouter, method::Symbol, path::AbstractString,
                             handler::Function; middleware::AbstractVector=Mongoose.AbstractMiddleware[],
                             metadata=nothing)
        push!(r.entries, (Regex("^" * String(path) * "\$"), method,
                          Mongoose.Endpoint(handler; middleware=middleware, metadata=metadata)))
        return r
    end

    function Mongoose.match_route(r::RegexRouter, method::Symbol, path::AbstractString)
        clean = Mongoose.strip_query(path)
        for (re, m, ep) in r.entries
            m === method || continue
            match(re, String(clean)) === nothing && continue
            return Mongoose.Matched(ep, Mongoose.SingleEndpoint(ep, method), ())
        end
        return Mongoose.NotFound()
    end
    function Mongoose.match_route_exact(r::RegexRouter, method::Symbol, path::AbstractString)
        m = Mongoose.match_route(r, method, path)
        return m isa Mongoose.Matched ? m : nothing
    end

    app = App(router=RegexRouter())
    get!(app, "/re/.*", req -> text("regex route"))
    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/re/anything"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "regex route"
        resp404 = HTTP.get("http://127.0.0.1:$port/other"; status_exception=false)
        @test resp404.status == 404
    end
end

