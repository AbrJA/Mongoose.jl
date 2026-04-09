using Mongoose

function greet(req)
    Response(Json, "{\"message\":\"Hello World from trimmed Julia!\"}")
end

function echo(req, name)
    Response("Hello $(String(name))!")
end

@router Routes begin
    get("/hello", greet)
    get("/echo/:name", echo)
end

(@main)(ARGS) = begin
    server = Server(Routes)
    start!(server, port=8099, blocking=true)
    return 0
end

# juliac --trim=safe --project . --output-exe binary example/juliac/server.jl 2>&1
