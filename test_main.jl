using Mongoose

function greet(request, params)
    body = "{\"message\":\"Hello World from trimmed Julia!\"}"
    Response(200, Dict("Content-Type" => "application/json"), body)
end

# Pre-wrap the handler for trim-safe compilation
const GREET_HANDLER = Handler(greet)

(@main)(ARGS) = begin
    server = AsyncServer()
    route!(server, :get, "/hello", GREET_HANDLER)
    start!(server, port=8098, blocking=true)
    return 0
end
