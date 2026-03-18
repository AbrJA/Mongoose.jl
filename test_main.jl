
using Mongoose

function greet(request::HttpRequest, params::Dict)
    body = "{\"message\":\"Hello World from trimmed Julia!\"}"
    Response(200, Dict("Content-Type" => "application/json"), body)
end

@main function main(args::Vector{String})
    try
        server = AsyncServer()
        route!(server, :get, "/hello", greet)
        start!(server, port=8098, blocking=false)
    finally
        shutdown!(server)
    end
    return 0
end
