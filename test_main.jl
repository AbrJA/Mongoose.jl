
using Mongoose

function greet(request::HttpRequest, params::Dict{String,String})
    body = "{\"message\":\"Hello World from trimmed Julia!\"}"
    Response(200, Dict("Content-Type" => "application/json"), body)
end

@main function main(args::Vector{String})
    server = AsyncServer()
    route!(server, :get, "/hello", greet)
    start!(server, port=8098, blocking=true)
    return 0
end
