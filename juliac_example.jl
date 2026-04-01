using Mongoose

function greet(req)
    Response(200, ContentType.json, "{\"message\":\"Hello World from trimmed Julia!\"}")
end

function echo(req, name)
    Response(200, ContentType.text, "Hello $(String(name))!")
end

@router Routes begin
    get("/hello", greet)
    get("/echo/:name", echo)
end

(@main)(ARGS) = begin
    server = SyncServer(Routes)
    start!(server, port=8099, blocking=true)
    return 0
end

# juliac --trim=safe --project . --output-exe binary juliac_example.jl 2>&1
