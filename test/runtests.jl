using Test
using HTTP
import JSON
using Mongoose

@testset "Mongoose.jl" begin
    include("helpers.jl")

    # ── Unit: no server, no FFI (protocol, router, middleware, executor) ──
    @testset "Unit: Request/Response protocol" begin
        include("unit/response.jl")
        include("unit/request.jl")
        include("unit/ws.jl")
    end

    @testset "Unit: Router core" begin
        include("unit/router.jl")
    end

    @testset "Unit: Middleware protocol" begin
        include("unit/middleware.jl")
    end

    @testset "Unit: Executor + Transport contracts" begin
        include("unit/executor.jl")
        include("unit/transport.jl")
    end

    @testset "Unit: Pipeline seam + validation" begin
        include("unit/pipeline.jl")
        include("unit/validation.jl")
    end

    @testset "Unit: FakeTransport (TestClient)" begin
        include("unit/testing.jl")
    end

    # ── Routing: dispatch behavior over live servers ──
    @testset "Routing" begin
        include("routing/protocol.jl")
        include("routing/registration.jl")
        include("routing/dsl.jl")
        include("routing/dispatch.jl")
        include("routing/edge.jl")
        include("routing/groups.jl")
        include("routing/query.jl")
        include("routing/pluggable.jl")
    end

    # ── Middleware: each component against a live server ──
    @testset "Middleware" begin
        include("middleware/cors.jl")
        include("middleware/ratelimit.jl")
        include("middleware/auth.jl")
        include("middleware/logger.jl")
        include("middleware/health.jl")
        include("middleware/metrics.jl")
        include("middleware/security.jl")
        include("middleware/negotiate.jl")
        include("middleware/pipeline.jl")
        include("middleware/path.jl")
        include("middleware/edge.jl")
    end

    # ── Server: lifecycle, errors, services ──
    @testset "Server" begin
        include("server/lifecycle.jl")
        include("server/edge.jl")
        include("server/errors.jl")
        include("server/services.jl")
        include("server/serverconfig.jl")
    end

    # ── HTTP features ──
    @testset "HTTP" begin
        include("http/features.jl")
        include("http/request.jl")
        include("http/errors.jl")
        include("http/formats.jl")
        include("http/streaming.jl")
    end

    @testset "Static Files" begin
        include("http/static.jl")
    end

    @testset "WebSocket" begin
        include("websocket/websocket.jl")
        include("websocket/edge.jl")
    end

    @testset "TLS" begin
        include("tls/tls.jl")
    end
end