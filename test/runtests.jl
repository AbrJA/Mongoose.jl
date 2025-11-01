using HTTP
using Mongoose
using Test

@testset "Mongoose.jl" begin
    function greet(request; kwargs...)
        body = "{\"message\":\"Hello World from Julia!\"}"
        Response(200, Dict("Content-Type" => "application/json"), body)
    end

    function echo(request; kwargs...)
        params = kwargs[:params]
        name = params[:name]
        body = "Hello $name from Julia!"
        Response(200, Dict("Content-Type" => "text/plain"), body)
    end

    register("GET", "/hello", greet)
    register("GET", "/echo/:name", echo)

    serve()

    response = HTTP.get("http://localhost:8080/hello")
    @test response.status == 200
    @test String(response.body) == "{\"message\":\"Hello World from Julia!\"}"

    response = HTTP.post("http://localhost:8080/hello"; status_exception=false)
    @test response.status == 405
    @test String(response.body) == "405 Method Not Allowed"

    response = HTTP.get("http://localhost:8080/nonexistent"; status_exception=false)
    @test response.status == 404
    @test String(response.body) == "404 Not Found"

    response = HTTP.get("http://localhost:8080/echo/Alice")
    @test response.status == 200
    @test String(response.body) == "Hello Alice from Julia!"

    response = HTTP.get("http://localhost:8080/echo/Bob/1"; status_exception=false)
    @test response.status == 404
    @test String(response.body) == "404 Not Found"

    shutdown()
end
