@testset "Router protocol (contract-by-fallback)" begin
    struct _FallbackRouter <: AbstractRouter end

    r = _FallbackRouter()
    # Optional capabilities default to "not supported".
    @test Mongoose.haswsroutes(r) == false
    @test Mongoose.wsendpoint(r, "/ws") === nothing
    @test Mongoose.length(r) == 0
    # Required protocol throws a clear MethodError when unimplemented.
    @test_throws MethodError Mongoose.matchroute(r, :get, "/")
    @test_throws MethodError Mongoose.hasroute(r, "/")
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

    function Mongoose.matchroute(r::RegexRouter, method::Symbol, path::AbstractString)
        clean = Mongoose.stripquery(path)
        for (re, m, ep) in r.entries
            m === method || continue
            match(re, String(clean)) === nothing && continue
            return Mongoose.Matched(ep, Mongoose.SingleEndpoint(ep, method), ())
        end
        return Mongoose.NoMatch()
    end
    function Mongoose.hasroute(r::RegexRouter, path::AbstractString)
        clean = Mongoose.stripquery(path)
        return any(e -> match(e[1], String(clean)) !== nothing, r.entries)
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

