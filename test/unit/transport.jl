@testset "Transport capability traits + FakeTransport (FFI-free)" begin
    # Router capability via the trait spelling.
    r = Router()
    @test Mongoose.supportsws(r) == false
    ws!(r, "/ws"; on_message=req -> nothing)
    @test Mongoose.supportsws(r) == true

    # A full request cycle with a fake transport, no server started.
    app = App()
    get!(app, "/hi") do req
        json((msg = "hi",))
    end
    use!(app, cors())

    client = FakeTransport(app)
    @test client isa AbstractTransport
    @test Mongoose.supportsws(client) == false
    @test Mongoose.supportstls(client) == false
    @test Mongoose.supportsstream(client) == true

    resp = client(:get, "/hi")
    @test resp.status == 200
    @test contains(String(resp.body), "hi")
    @test app.runtime.running[] == false  # never started the C server

    # TestClient is the same fake transport (compat alias).
    @test Mongoose.TestClient === FakeTransport
end
