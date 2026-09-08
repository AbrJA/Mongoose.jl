@testset "Custom error responses" begin
    app = App()
    get!(app, "/") do req; text("ok") end
    onerror!(app, 404, Response(404, Pair{String,String}[], "Custom Not Found"))

    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/nonexistent"; status_exception=false)
        @test resp.status == 404
        @test contains(String(resp.body), "Not Found")
    end
end

@testset "onerror! validation" begin
    app = App()
    @test_throws ServerError onerror!(app, 99, Response(99, Pair{String,String}[], "bad"))
    @test_throws ServerError onerror!(app, 600, Response(600, Pair{String,String}[], "bad"))
end

