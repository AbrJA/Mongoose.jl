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

