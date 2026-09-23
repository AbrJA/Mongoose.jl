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
        @test Mongoose.getwsendpoint(r, "/ws").allowed_origins == ["https://a.test"]
    end

    r = Router()
    ws!(r, "/ws"; on_message = m -> nothing)
    @test Mongoose.getwsendpoint(r, "/ws").allowed_origins == String[]
    @test Mongoose.haswsroutes(r)
end

@testset "ws! positional handler" begin
    # Router, server, and group all accept the HTTP-DSL handler placement.
    r = Router()
    ws!(r, "/ws", m -> Message("pong"))
    @test Mongoose.getwsendpoint(r, "/ws") !== nothing

    ws!(r, "/w2", m -> nothing; allowed_origins=("https://a.test",))
    @test Mongoose.getwsendpoint(r, "/w2").allowed_origins == ["https://a.test"]

    app = App()
    @test ws!(app, "/ws", m -> Message("pong")) === app
    @test Mongoose.getwsendpoint(app.router, "/ws") !== nothing

    g = group("/g")
    ws!(g, "/ws", m -> Message("pong"))
    @test length(g.ws_routes) == 1
    mount!(app, g)
    @test Mongoose.getwsendpoint(app.router, "/g/ws") !== nothing

    g2 = group("/g2")
    ws!(g2, "/ws", m -> nothing; allowed_origins=("https://a.test",))
    app2 = App()
    mount!(app2, g2)
    @test Mongoose.getwsendpoint(app2.router, "/g2/ws").allowed_origins == ["https://a.test"]
end


@testset "WS connection generation ids" begin
    app = App()
    ws!(app, "/ws"; on_message = m -> nothing)

    c1 = Ptr{Cvoid}(0x1000 % UInt)
    id1 = Mongoose.ws_register!(app, "/ws", c1)
    @test app.runtime.ws_gen_ids[c1] == id1
    @test app.runtime.connections[id1] == c1
    @test haskey(app.runtime.ws_clients, id1)

    Mongoose.on_connection_close(app, c1, C_NULL)
    @test !haskey(app.runtime.ws_gen_ids, c1)
    @test !haskey(app.runtime.connections, id1)
    @test !haskey(app.runtime.ws_clients, id1)

    # A new connection reusing the same address gets a fresh generation id, so
    # a stale worker reply can never be delivered to it.
    c2 = Ptr{Cvoid}(0x1000 % UInt)
    id2 = Mongoose.ws_register!(app, "/ws", c2)
    @test id2 != id1
    @test app.runtime.ws_gen_ids[c2] == id2
    Mongoose.on_connection_close(app, c2, C_NULL)
    @test isempty(app.runtime.ws_gen_ids)
end
