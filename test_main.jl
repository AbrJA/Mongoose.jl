using Mongoose

function greet(request::HttpRequest, params::Dict)
    body = "{\"message\":\"Hello World from trimmed Julia!\"}"
    Response(200, Dict("Content-Type" => "application/json"), body)
end

# Fallback for the @main macro evaluation which executes `main(main)`
main(f::Function) = 0

@main function main(args::Vector{String})
    if ccall(:jl_generating_output, Cint, ()) == 1
        return 0
    end
    
    server = AsyncServer()
    route!(server, :get, "/hello", greet)
    start!(server, port=8098, blocking=false)
    
    sleep(2.0)
    
    # We do not make a request with HTTP.jl here because HTTP.jl uses many abstract 
    # structures which fail the stringent type inference verifier in JuliaC `--trim=safe`.
    # A standalone test with CURL will show that the port is open and server logic responds.
    
    shutdown!(server)
    return 0
end
