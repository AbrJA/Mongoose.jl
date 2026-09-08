@testset "CORS middleware" begin
    @testset "Preflight OPTIONS request (allowed origin)" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors())

        with_server(s) do port
            resp = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api";
                                headers=["Origin" => "https://app.example"],
                                status_exception=false)
            @test resp.status == 204
            headers = Dict(resp.headers)
            @test headers["Access-Control-Allow-Origin"] == "*"
            @test headers["Vary"] == "Origin"
            @test !haskey(headers, "Access-Control-Allow-Credentials")
        end
    end

    @testset "Preflight rejected for foreign origin" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(origins=["https://app.example"]))

        with_server(s) do port
            ok = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api";
                              headers=["Origin" => "https://app.example"],
                              status_exception=false)
            @test ok.status == 204
            @test Dict(ok.headers)["Access-Control-Allow-Origin"] == "https://app.example"

            evil = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api";
                                headers=["Origin" => "https://evil.example"],
                                status_exception=false)
            @test evil.status == 403
        end
    end

    @testset "Preflight validates method and headers" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(methods="GET, POST", headers="X-Custom, Content-Type", max_age=3600))

        with_server(s) do port
            # Allowed method + headers
            ok = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api";
                              headers=["Origin" => "https://a.example",
                                       "Access-Control-Request-Method" => "POST",
                                       "Access-Control-Request-Headers" => "X-Custom"],
                              status_exception=false)
            @test ok.status == 204
            headers = Dict(ok.headers)
            @test headers["Access-Control-Allow-Methods"] == "GET, POST"
            @test headers["Access-Control-Allow-Headers"] == "X-Custom, Content-Type"
            @test headers["Access-Control-Max-Age"] == "3600"

            # Unallowed method → 403
            bad = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api";
                               headers=["Origin" => "https://a.example",
                                        "Access-Control-Request-Method" => "DELETE"],
                               status_exception=false)
            @test bad.status == 403
        end
    end

    @testset "CORS headers on regular requests (origin echo)" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(origins="https://example.com"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api";
                            headers=["Origin" => "https://example.com"],
                            status_exception=false)
            @test resp.status == 200
            headers = Dict(resp.headers)
            @test headers["Access-Control-Allow-Origin"] == "https://example.com"
            @test headers["Vary"] == "Origin"

            # Foreign origin gets no CORS headers.
            foreign = HTTP.get("http://127.0.0.1:$port/api";
                               headers=["Origin" => "https://other.example"],
                               status_exception=false)
            @test !haskey(Dict(foreign.headers), "Access-Control-Allow-Origin")
        end
    end

    @testset "Credentials mode reflects origin (no wildcard)" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, cors(origins=["https://app.example"], allow_credentials=true))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api";
                            headers=["Origin" => "https://app.example"],
                            status_exception=false)
            headers = Dict(resp.headers)
            @test headers["Access-Control-Allow-Origin"] == "https://app.example"
            @test headers["Access-Control-Allow-Credentials"] == "true"
        end
    end
end