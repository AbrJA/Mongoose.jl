using Mongoose
using Test

@testset "Mongoose.jl" begin
    function greet(conn, request)
        # @info mg_body(request)
        mg_json_reply(conn, 200, json)
    end

    mg_register("GET", "/hello", greet)

    mg_serve()
    sleep(10)
    mg_shutdown()
end
