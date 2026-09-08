@testset "CORS middleware" begin
    @testset "Preflight OPTIONS request" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors())

        with_server(s) do port
            resp = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 204
            headers = Dict(resp.headers)
            @test haskey(headers, "Access-Control-Allow-Origin")
            @test headers["Access-Control-Allow-Origin"] == "*"
        end
    end

    @testset "CORS headers on regular requests" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(origins="https://example.com"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 200
            headers = Dict(resp.headers)
            @test headers["Access-Control-Allow-Origin"] == "https://example.com"
        end
    end

    @testset "Custom CORS methods and headers" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(methods="GET, POST", headers="X-Custom", max_age=3600))

        with_server(s) do port
            resp = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 204
            headers = Dict(resp.headers)
            @test headers["Access-Control-Allow-Methods"] == "GET, POST"
            @test headers["Access-Control-Allow-Headers"] == "X-Custom"
            @test headers["Access-Control-Max-Age"] == "3600"
        end
    end
end

