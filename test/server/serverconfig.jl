@testset "ServerConfig" begin
    @testset "config stores tuning parameters" begin
        app = App(workers=2, max_body_bytes=1024, poll_timeout_ms=5)
        @test app.config.workers == 2
        @test app.config.max_body_bytes == 1024
        @test app.config.poll_timeout_ms == 5
        @test app.config isa Mongoose.ServerConfig
        @test app.config.workers == 2
    end

    @testset "config validates parameters" begin
        @test_throws Mongoose.ServerError App(max_body_bytes=0)
        @test_throws Mongoose.ServerError App(workers=-1)
        @test_throws Mongoose.ServerError App(poll_timeout_ms=-1)
    end
end

