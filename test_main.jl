using Mongoose

function greet(req)
    Response(200, "Content-Type: application/json\r\n", "{\"message\":\"Hello World from trimmed Julia!\"}")
end

function echo(req, name)
    Response(200, "Content-Type: text/plain\r\n", "Hello $(String(name))!")
end

@router NewRouter begin
    get("/hello", greet)
    get("/echo/:name", echo)
end

(@main)(ARGS) = begin
    server = SyncServer(NewRouter)
    start!(server, port=8099, blocking=true)
    return 0
end
