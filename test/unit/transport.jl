@testset "Transport capability traits + FakeTransport (FFI-free)" begin
    # Router contents use `haswsroutes`; `can*` is transport capability only.
    r = Router()
    @test Mongoose.haswsroutes(r) == false
    ws!(r, "/ws"; on_message=req -> nothing)
    @test Mongoose.haswsroutes(r) == true

    # A full request cycle with a fake transport, no server started.
    app = App()
    get!(app, "/hi") do req
        json((msg = "hi",))
    end
    use!(app, cors())

    client = FakeTransport(app)
    @test client isa AbstractTransport
    @test Mongoose.canws(client) == false
    @test Mongoose.cantls(client) == false
    @test Mongoose.canstream(client) == true

    resp = client(:get, "/hi")
    @test resp.status == 200
    @test contains(String(resp.body), "hi")
    @test app.runtime.running[] == false  # never started the C server
end
