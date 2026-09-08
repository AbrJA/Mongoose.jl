@testset "Transport capability traits + FakeTransport (FFI-free)" begin
    # Router capability via the trait spelling.
    r = Router()
    @test Mongoose.supports_websocket(r) == false
    ws!(r, "/ws"; on_message=req -> nothing)
    @test Mongoose.supports_websocket(r) == true

    # A full request cycle with a fake transport, no server started.
    app = App()
    get!(app, "/hi") do req
        json((msg = "hi",))
    end
    use!(app, cors())

    client = FakeTransport(app)
    @test client isa AbstractTransport
    @test Mongoose.supports_websocket(client) == false
    @test Mongoose.supports_tls(client) == false
    @test Mongoose.supports_streaming(client) == true

    resp = client(:get, "/hi")
    @test resp.status == 200
    @test contains(String(resp.body), "hi")
    @test app.running[] == false  # never started the C server

    # TestClient is the same fake transport (compat alias).
    @test Mongoose.TestClient === FakeTransport
end
