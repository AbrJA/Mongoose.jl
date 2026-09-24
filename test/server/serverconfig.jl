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


@testset "receive-buffer ceiling" begin
    # Empirically verified on the current Mongoose_jll: 8 MiB round-trips,
    # 10 MiB resets the connection — so limits above the ceiling are refused
    # at construction instead of failing mysteriously at runtime.
    @test_throws Mongoose.ServerError App(max_body_bytes=9 * 1024 * 1024)
    @test_throws Mongoose.ServerError App(ws_max_frame_bytes=9 * 1024 * 1024)
    @test App(max_body_bytes=8 * 1024 * 1024).config.max_body_bytes == 8 * 1024 * 1024
end

@testset "new limit config" begin
    app = App(header_timeout_ms=500, max_connections=10)
    @test app.config.header_timeout_ms == 500
    @test app.config.max_connections == 10
    @test_throws Mongoose.ServerError App(header_timeout_ms=-1)
    @test_throws Mongoose.ServerError App(max_connections=-1)

    limits = App(body_timeout_ms=500, max_header_bytes=2048)
    @test limits.config.body_timeout_ms == 500
    @test limits.config.max_header_bytes == 2048
    @test App().config.max_header_bytes == Mongoose.DEFAULT_MAX_HEADER_BYTES
    @test_throws Mongoose.ServerError App(body_timeout_ms=-1)
    @test_throws Mongoose.ServerError App(max_header_bytes=-1)
    @test_throws Mongoose.ServerError App(max_header_bytes=Mongoose.C_RECV_CEILING_BYTES + 1)
end
