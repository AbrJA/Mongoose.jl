using HTTP
using Mongoose
using Test

@testset "Mongoose.jl" begin
    function greet(conn, request)
        mg_json_reply(conn, 200, "{\"message\":\"Hello World from Julia!\"}")
    end

    function echo(conn, request; kwargs...)
        params = kwargs[:params]
        name = params[:name]
        body = "Hello $name from Julia!"
        mg_text_reply(conn, 200, body)
    end

    mg_register!("GET", "/hello", greet)
    mg_register!("GET", "/echo/:name", echo)

    mg_serve!()

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

    mg_shutdown!()
end
