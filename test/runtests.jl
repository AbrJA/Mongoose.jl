using HTTP
using JSON
using Mongoose
using Test

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

# Module-level @router definitions must live at top level (macro expands to module decls).
# They are referenced by routing and websocket tests included below.
@router Routes begin
    get("/hello", (req) -> Response(200, "", "Hello Static"))
    get("/user/:id::Int", (req, id) -> Response(200, "", "User $id"))
    ws("/chat", on_message=(msg) -> Message("Echo: $(msg.data)"))
end

@router WildcardApp begin
    get("/known",  req -> Response(200, "", "known"))
    get("/*path",  (req, path) -> Response(404, "", "not found: $path"))
end

@router TypedApp begin
    get("/item/:id::Int", (req, id) -> Response(200, "", "id=$id type=$(typeof(id))"))
end

@router PrecedenceApp begin
    get("/match/exact", req -> Response(200, "", "exact"))
    get("/match/:id::Int", (req, id) -> Response(200, "", "typed:$id"))
    get("/*rest", (req, rest) -> Response(404, "", "wild:$rest"))
end

@testset "Mongoose.jl" begin
    include("helpers.jl")
    include("server.jl")
    include("tls.jl")
    include("routing.jl")
    include("middleware.jl")
    include("http.jl")
    include("websocket.jl")
    include("static.jl")
    include("unit.jl")
end

