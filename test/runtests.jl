using Test
using HTTP
using JSON
using Mongoose

# Extend Mongoose.encode for JSON serialization (required for Json format)
Mongoose.encode(::Type{Json}, body::AbstractDict) = JSON.json(body)
Mongoose.encode(::Type{Json}, body::AbstractVector) = JSON.json(body)

# --- @router macro (must be at top level) ---

@router TestRoutes begin
    get("/hello", (req) -> Response(200, "", "Hello Static"))
    get("/user/:id::Int", (req, id) -> Response(200, "", "User $id"))
    get("/file/*path", (req, path) -> Response(200, "", "File: $path"))
    ws("/chat", on_message=(msg) -> Message("Echo: $(msg.data)"))
end

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
end
