# Compiled frozen-route dispatch: semantic parity with the generic dispatch
# path, plus the AOT/trim-friendly contract (freeze! → per-route codegen via
# `terminal_for`).

import Mongoose: AbstractMiddleware, match_route, freeze!, invoke_request,
    terminal_for, isfrozen, RouteError, RequestContext

mkreq(method, path) = Request(method, path, Dict{String,String}(),
    Pair{String,String}[], "")

# Seam helper: build a RequestContext over a router for these tests (empty
# error pages by default; middleware/services overridable).
mkctx(r; mws=AbstractMiddleware[], errs=ERRORS, svcs=NamedTuple()) =
    RequestContext(r; middlewares=mws, errors=errs, services=svcs)

# --- Registry of routes and probe requests (mirror routers) ---

function _sample_router!(r)
    route!(r, :get,    "/health",               req -> text("ok"))
    route!(r, :post,   "/health",               req -> text("posted"))
    route!(r, :put,    "/health",               req -> text("put"))
    route!(r, :delete, "/health",               req -> text("del"))
    route!(r, :patch,  "/health",               req -> text("patch"))
    route!(r, :options,"/health",               req -> text("opts"))
    route!(r, :head,   "/health",               req -> text("head"))
    route!(r, :get,    "/users/:id::Int",       (req, id) -> text("u:$id:$(typeof(id))"))
    route!(r, :get,    "/users/:name",          (req, name) -> text("name:$name"))
    route!(r, :get,    "/org/:org/repo/:repo",  (req, org, repo) -> text("$org/$repo"))
    route!(r, :get,    "/temp/:val::Float64",   (req, val) -> text("t=$val"))
    route!(r, :get,    "/flag/:v::Bool",        (req, v) -> text("f=$v"))
    route!(r, :get,    "/id/:n::UInt",          (req, n) -> text("n=$n"))
    route!(r, :get,    "/api/:v/users/:uid::Int/posts/:pid::Int",
        (req, v, uid, pid) -> text("$v:$uid:$pid"))
    route!(r, :get,    "/files/*path",          (req, path) -> text("path=$path"))
    route!(r, :get,    "/search",               req -> text("q=$(get(req.query, "q", "none"))"))
    route!(r, :get,    "/*deep",                (req, deep) -> text("catch:$deep"))
    route!(r, :get,    "/scop", req -> text("s"); middleware=[_NoopMw("x")])
    return r
end

# Route-scoped middleware must run (and pass through) on the compiled path.
struct _NoopMw <: AbstractMiddleware
    tag::String
end
(mw::_NoopMw)(req::Request, next::Function) = next()

struct _PassMw <: AbstractMiddleware
    tag::String
    sink::Vector{String}
end
(mw::_PassMw)(req::Request, next::Function) = (push!(mw.sink, mw.tag); next())

const ERRORS = Dict{Int,Union{Response,Function}}()

@testset "Compiled dispatch: 404/405/HEAD parity (frozen vs generic)" begin
    # Same routes: one frozen (compiled), one open (generic dispatch).
    rf = freeze!(_sample_router!(Router()))
    rg = _sample_router!(Router())

    probes = [
        (:get,    "/health"), (:post, "/health"), (:put, "/health"),
        (:delete, "/health"), (:patch, "/health"), (:options, "/health"),
        (:head,   "/health"),                       # explicit HEAD route
        (:get,    "/health?x=1"),                   # query stripped
        (:get,    "/users/42"),                     # Int param wins (order)
        (:get,    "/users/42.5"),                   # Int fails → String route
        (:get,    "/users/alice"),
        (:get,    "/org/julia/repo/mongoose"),
        (:get,    "/temp/36.6"),                    # Float64
        (:get,    "/temp/abc"),                     # parse fail → 404
        (:get,    "/flag/true"), (:get, "/flag/false"), (:get, "/flag/maybe"),
        (:get,    "/id/42"), (:get, "/id/-1"),
        (:get,    "/api/v2/users/5/posts/10"),
        (:get,    "/files/a/b/c.txt"),              # wildcard with prefix
        (:get,    "/files"),                        # wildcard with empty capture
        (:get,    "/foo/bar/baz"),                  # bare catch-all
        (:get,    "/nope"),                         # 404
        (:post,   "/users/42"),                     # 405 (route has other methods)
        (:head,   "/users/42"),                     # 405: no auto-HEAD
        (:head,   "/org/julia/repo/mongoose"),      # 405: no auto-HEAD
        (:head,   "/files/x/y.txt"),                # 405: no auto-HEAD
        (:get,    "/search?q=hello&page=1"),        # query + fixed
        (:get,    "/scop"),                         # route-scoped middleware
        (:get,    "/health//"),                     # trailing slashes (keepempty)
        (:get,    "/users//42"),                    # empty segment collapsed
        (:get,    "/users/john%20doe"),             # URL-decoded param
        (:get,    "/users/a+b"),                    # '+' stays literal in paths
    ]

    for (method, path) in probes
        req = mkreq(method, path)
        rf_resp = invoke_request(mkctx(rf), req)
        rg_resp = invoke_request(mkctx(rg), req)
        @test rf_resp.status == rg_resp.status
        @test rf_resp.body == rg_resp.body
    end
end

@testset "Compiled dispatch: match_route still agrees" begin
    rf = freeze!(_sample_router!(Router()))
    rg = _sample_router!(Router())
    for (method, path) in [(:get, "/users/42"), (:get, "/users/alice"),
                           (:get, "/files/a/b.txt"), (:get, "/x/y/z"),
                           (:get, "/missing"), (:get, "/health")]
        mf = match_route(rf, method, path)
        mg = match_route(rg, method, path)
        @test (mf isa Mongoose.NotFound) == (mg isa Mongoose.NotFound)
        if mf isa Mongoose.NotFound
            @test mg isa Mongoose.NotFound
            continue
        end
        @test (mf isa Mongoose.MethodNotAllowed) == (mg isa Mongoose.MethodNotAllowed)
        if mf isa Mongoose.MethodNotAllowed
            @test mf.allowed == mg.allowed
            continue
        end
        @test mf.params == mg.params
        hf = Mongoose.get_handler(mf, method)
        hg = Mongoose.get_handler(mg, method)
        @test (hf === nothing) == (hg === nothing)
    end
end

@testset "Compiled dispatch: terminal_for contract" begin
    r = Router()
    get!(r, "/a", req -> text("a"))
    # Unfrozen routers fall back to the generic pipeline.
    @test terminal_for(r, mkreq(:get, "/a")) === nothing
    freeze!(r)
    @test terminal_for(r, mkreq(:get, "/a")) !== nothing
    @test terminal_for(r, mkreq(:get, "/missing")) !== nothing  # 404 terminal

    # Empty frozen router → 404 through the compiled path.
    re = freeze!(Router())
    resp = invoke_request(mkctx(re),
        mkreq(:get, "/anything"))
    @test resp.status == 404

    # Frozen routers still reject registration.
    @test_throws RouteError route!(r, :get, "/b", req -> text("b"))
    @test_throws RouteError ws!(r, "/ws"; on_message=req -> nothing)
    @test isfrozen(r)
end

@testset "Compiled dispatch: scoped middleware order" begin
    sink = String[]
    r = Router()
    route!(r, :get, "/scop", req -> text("ok");
        middleware=[_NoopMw("m1"), _NoopMw("m2")])
    freeze!(r)

    passthrough = _PassMw("global", sink)
    resp = invoke_request(mkctx(r; mws=AbstractMiddleware[passthrough]),
        mkreq(:get, "/scop"))
    @test resp.status == 200
    @test resp.body == "ok"
    # Global middleware still wraps the compiled (scoped-fused) terminal.
    @test sink == ["global"]

    # Global-only middleware over a scoped-free compiled terminal — parity
    # with the generic path (which concatenates [global; scoped]).
    rf = freeze!(_sample_router!(Router()))
    rgo = _sample_router!(Router())
    for (method, path) in [(:get, "/health"), (:get, "/users/42"),
                           (:head, "/org/julia/repo/mongoose"), (:get, "/nope")]
        rf_resp = invoke_request(mkctx(rf; mws=AbstractMiddleware[_PassMw("g", sink)]),
            mkreq(method, path))
        rg_resp = invoke_request(mkctx(rgo; mws=AbstractMiddleware[_PassMw("g", sink)]),
            mkreq(method, path))
        @test rf_resp.status == rg_resp.status
        @test rf_resp.body == rg_resp.body
    end
end

@testset "Compiled dispatch: error remap + services still apply" begin
    r = Router()
    get!(r, "/svc", req -> text(string(service(req, Val(:db)))))
    freeze!(r)
    resp = invoke_request(mkctx(r; svcs=(db=42,)),
        mkreq(:get, "/svc"))
    @test String(resp.body) == "42"

    errs = Dict{Int,Union{Response,Function}}(
        404 => Response(Plain, "custom 404"; status=404))
    resp = invoke_request(mkctx(r; errs=errs),
        mkreq(:get, "/missing"))
    @test resp.status == 404
    @test String(resp.body) == "custom 404"
end

@testset "Compiled dispatch: live server with a frozen router" begin
    app = App(router=freeze!(_sample_router!(Router())))
    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/health"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "ok"

        resp = HTTP.get("http://127.0.0.1:$port/users/42"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "u:42:Int64"

        resp = HTTP.get("http://127.0.0.1:$port/files/a/b.txt"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "path=a/b.txt"

        resp = HTTP.get("http://127.0.0.1:$port/missing"; status_exception=false)
        # The bare `/*deep` catch-all handles any GET path.
        @test resp.status == 200

        # … but only for GET: other methods fall through to 405.
        resp = HTTP.request("PATCH", "http://127.0.0.1:$port/missing"; status_exception=false)
        @test resp.status == 405

        resp = HTTP.request("POST", "http://127.0.0.1:$port/users/42"; status_exception=false)
        @test resp.status == 405

        # HEAD is served only by an explicit head! route: /users/42 is GET-only,
        # so HEAD answers 405 with an Allow header that lists no HEAD.
        resp = HTTP.head("http://127.0.0.1:$port/users/42"; status_exception=false)
        @test resp.status == 405
        allow = HTTP.header(resp, "Allow")
        @test occursin("GET", allow)
        @test !occursin("HEAD", allow)
    end
end