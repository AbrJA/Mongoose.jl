using Test
using HTTP
import JSON
using Mongoose

@testset "Mongoose.jl" begin
    include("helpers.jl")

    @testset "Unit Tests" begin
        include("unit.jl")
    end

    @testset "Server Lifecycle" begin
        include("server.jl")
    end

    @testset "Routing" begin
        include("routing.jl")
    end

    @testset "Middleware" begin
        include("middleware.jl")
    end

    @testset "HTTP Features" begin
        include("http.jl")
    end

    @testset "WebSocket" begin
        include("websocket.jl")
    end

    @testset "Static Files" begin
        include("static.jl")
    end

    @testset "TLS" begin
        include("tls.jl")
    end

    @testset "Features & Edge Cases" begin
        include("features.jl")
    end

    @testset "New Features (v0.5.0)" begin
        include("new_features.jl")
    end
end
