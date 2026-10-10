@testset "Method helpers on App" begin
    app = App()
    route!(app, :get, "/g") do req; text("get") end
    route!(app, :post, "/p") do req; text("post") end
    route!(app, :put, "/u") do req; text("put") end
    route!(app, :patch, "/pa") do req; text("patch") end
    route!(app, :delete, "/d") do req; text("delete") end

    with_server(app) do port
        @test HTTP.get("http://127.0.0.1:$port/g"; status_exception=false).status == 200
        @test HTTP.post("http://127.0.0.1:$port/p", []; status_exception=false).status == 200
        @test HTTP.request("PUT", "http://127.0.0.1:$port/u"; status_exception=false).status == 200
        @test HTTP.request("PATCH", "http://127.0.0.1:$port/pa"; status_exception=false).status == 200
        @test HTTP.request("DELETE", "http://127.0.0.1:$port/d"; status_exception=false).status == 200
    end
end

@testset "route! middleware= input forms" begin
    for mws in (cors(), (cors(),), [cors()])
        app = App()
        route!(app, :get, "/x", req -> text("x"); middleware=mws)
        resp = Mongoose.FakeTransport(app)(:get, "/x"; headers=["Origin" => "https://a.test"])
        @test resp.status == 200
        @test get(resp.headers, "access-control-allow-origin", nothing) == "*"
    end

    app = App()
    route!(app, :get, "/x", req -> text("x"); middleware=nothing)
    resp = Mongoose.FakeTransport(app)(:get, "/x"; headers=["Origin" => "https://a.test"])
    @test get(resp.headers, "access-control-allow-origin", nothing) === nothing
end

@testset "route! matchmethod accepts any case" begin
    app = App()
    route!(app, :GET, "/a", req -> text("a"))
    route!(app, "GeT", "/b", req -> text("b"))
    client = Mongoose.FakeTransport(app)
    @test client(:get, "/a").status == 200
    @test client(:get, "/b").status == 200

    # matchroute accepts String and uppercase Symbols too.
    @test Mongoose.matchroute(app.router, "GET", "/a") isa Mongoose.Matched
    @test Mongoose.matchroute(app.router, :GET, "/a") isa Mongoose.Matched
    @test_throws Mongoose.RouteError Mongoose.route!(app, :brew, "/c", req -> text("c"))
end

@testset "App-level router introspection" begin
    app = App()
    route!(app, :get, "/a") do req; text("a") end
    ws!(app, "/ws", m -> nothing)

    @test length(app) == 1
    @test !isempty(app)
    @test isempty(App())
    @test Mongoose.hasroute(app, "/a")
    @test !Mongoose.hasroute(app, "/b")
    @test Mongoose.matchroute(app, :get, "/a") isa Mongoose.Matched
    @test Mongoose.matchroute(app, "GET", "/missing") isa Mongoose.NoMatch
    @test Mongoose.haswsroutes(app)
    @test Mongoose.getwsendpoint(app, "/ws") !== nothing

    @test !isfrozen(app)
    @test freeze!(app) === app
    @test isfrozen(app)
    @test_throws Mongoose.RouteError route!(app, :get, "/late", req -> text("x"))
    @test_throws Mongoose.RouteError ws!(app, "/late", m -> nothing)
end


@testset "ws! do-block form" begin
    app = App()
    ws!(app, "/chat") do msg
        Message("Echo: " * String(msg.data))
    end
    @test Mongoose.haswsroutes(app)
    ep = Mongoose.getwsendpoint(app, "/chat")
    @test ep !== nothing
    @test ep.on_message(Message("hi")).data == "Echo: hi"

    r = Router()
    ws!(r, "/chat") do msg
        Message("r")
    end
    @test Mongoose.Kernel.haswsroutes(r)
end
