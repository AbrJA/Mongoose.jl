@testset "ServerConfig" begin
    @testset "config stores tuning parameters" begin
        app = App(workers=2, max_body=1024, poll_timeout=5)
        @test app.workers == 2
        @test app.max_body == 1024
        @test app.poll_timeout == 5
        @test app.config isa Mongoose.ServerConfig
        @test app.config.workers == 2
    end

    @testset "config validates parameters" begin
        @test_throws Mongoose.ServerError App(max_body=0)
        @test_throws Mongoose.ServerError App(workers=-1)
        @test_throws Mongoose.ServerError App(poll_timeout=-1)
    end
end

