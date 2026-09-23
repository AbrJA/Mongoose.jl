@testset "Router protocol (contract-by-fallback)" begin
    struct _FallbackRouter <: AbstractRouter end

    r = _FallbackRouter()
    # Optional capabilities default to "not supported".
    @test Mongoose.haswsroutes(r) == false
    @test Mongoose.getwsendpoint(r, "/ws") === nothing
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

@testset "Custom endpoint type (invokeendpoint seam)" begin
    # A router may carry its own endpoint type as long as it implements
    # `invokeendpoint` (and optionally `endpointmiddleware`).
    struct MyEndpoint
        handler::Function
    end
    struct MyRouter <: AbstractRouter
        entries::Vector{Tuple{String,Symbol,MyEndpoint}}
    end
    MyRouter() = MyRouter(Tuple{String,Symbol,MyEndpoint}[])

    Mongoose.invokeendpoint(ep::MyEndpoint, req::Request, params) = ep.handler(req)

    function Mongoose.route!(r::MyRouter, method::Symbol, path::AbstractString,
                             handler::Function; middleware=nothing, metadata=nothing)
        push!(r.entries, (String(path), method, MyEndpoint(handler)))
        return r
    end
    function Mongoose.matchroute(r::MyRouter, method::Symbol, path::AbstractString)
        clean = String(Mongoose.stripquery(path))
        for (p, m, ep) in r.entries
            m === method && p == clean && return Mongoose.Matched(ep, Mongoose.SingleEndpoint(ep, method), ())
        end
        return Mongoose.NoMatch()
    end
    Mongoose.hasroute(r::MyRouter, path::AbstractString) =
        any(e -> e[1] == String(Mongoose.stripquery(path)), r.entries)

    app = App(router=MyRouter())
    get!(app, "/mine", req -> text("custom endpoint"))
    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/mine"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "custom endpoint"
    end

    # Without invokeendpoint, dispatch fails loudly rather than type-erroring.
    struct BareEndpoint
        handler::Function
    end
    @test_throws MethodError Mongoose.invokeendpoint(
        BareEndpoint(req -> text("x")),
        Mongoose.Request(:get, "/", Dict{String,String}(), Pair{String,String}[], ""), ())
end

