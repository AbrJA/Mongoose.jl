@testset "Message type" begin
    @testset "String message" begin
        m = Message("hello")
        @test m.data == "hello"
    end

    @testset "Binary message" begin
        m = Message(UInt8[1, 2, 3])
        @test m.data == UInt8[1, 2, 3]
    end
end

@testset "ws! allowed_origins input forms" begin
    for origins in ("https://a.test", ("https://a.test",), ["https://a.test"])
        r = Router()
        ws!(r, "/ws"; on_message = m -> nothing, allowed_origins=origins)
        @test Mongoose.wsendpoint(r, "/ws").allowed_origins == ["https://a.test"]
    end

    r = Router()
    ws!(r, "/ws"; on_message = m -> nothing)
    @test Mongoose.wsendpoint(r, "/ws").allowed_origins == String[]
    @test Mongoose.haswsroutes(r)
end

@testset "ws! positional handler" begin
    # Router, server, and group all accept the HTTP-DSL handler placement.
    r = Router()
    ws!(r, "/ws", m -> Message("pong"))
    @test Mongoose.wsendpoint(r, "/ws") !== nothing

    ws!(r, "/w2", m -> nothing; allowed_origins=("https://a.test",))
    @test Mongoose.wsendpoint(r, "/w2").allowed_origins == ["https://a.test"]

    app = App()
    @test ws!(app, "/ws", m -> Message("pong")) === app
    @test Mongoose.wsendpoint(app.router, "/ws") !== nothing

    g = group("/g")
    ws!(g, "/ws", m -> Message("pong"))
    @test length(g.ws_routes) == 1
    mount!(app, g)
    @test Mongoose.wsendpoint(app.router, "/g/ws") !== nothing

    g2 = group("/g2")
    ws!(g2, "/ws", m -> nothing; allowed_origins=("https://a.test",))
    app2 = App()
    mount!(app2, g2)
    @test Mongoose.wsendpoint(app2.router, "/g2/ws").allowed_origins == ["https://a.test"]
end

