@testset "Static file serving" begin
    mktempdir() do dir
        # Create test files
        write(joinpath(dir, "index.html"), "<html><body>Hello</body></html>")
        write(joinpath(dir, "style.css"), "body { color: red; }")
        write(joinpath(dir, "app.js"), "console.log('hello');")
        write(joinpath(dir, "data.json"), """{"key":"value"}""")
        write(joinpath(dir, "readme.txt"), "A plain text file")

        mkdir(joinpath(dir, "sub"))
        write(joinpath(dir, "sub", "nested.html"), "<p>nested</p>")

        @testset "Serves HTML file" begin
            router = Router()
            route!(router, :get, "/api", req -> Response(200, "", "api"))
            s = Server(router)
            mount!(s, dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/index.html"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "<html>")
            end
        end

        @testset "Serves CSS file" begin
            router = Router()
            s = Server(router)
            mount!(s, dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/style.css"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "color: red")
            end
        end

        @testset "Serves JS file" begin
            router = Router()
            s = Server(router)
            mount!(s, dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/app.js"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "console.log")
            end
        end

        @testset "Serves nested files" begin
            router = Router()
            s = Server(router)
            mount!(s, dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/sub/nested.html"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "nested")
            end
        end

        @testset "Returns 404 for missing file" begin
            router = Router()
            s = Server(router)
            mount!(s, dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/nonexistent.txt"; status_exception=false)
                @test resp.status == 404
            end
        end

        @testset "API routes coexist with static files" begin
            router = Router()
            route!(router, :get, "/api/data", req -> Response(Json, """{"api":true}"""))
            s = Server(router)
            mount!(s, dir)

            with_server(s) do port
                # API route works
                resp = HTTP.get("http://127.0.0.1:$port/api/data"; status_exception=false)
                @test resp.status == 200
                @test JSON.parse(String(resp.body))["api"] == true

                # Static file works
                resp2 = HTTP.get("http://127.0.0.1:$port/readme.txt"; status_exception=false)
                @test resp2.status == 200
                @test String(resp2.body) == "A plain text file"
            end
        end

        @testset "Mount with custom prefix" begin
            router = Router()
            s = Server(router)
            mount!(s, dir; uri_prefix="/static")

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/static/index.html"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "<html>")
            end
        end
    end
end

@testset "mount! validation" begin
    @test_throws ArgumentError mount!(Server(), "/nonexistent/path/xyz")
end

@testset "Binary file serving" begin
    mktempdir() do dir
        # Create a binary file
        binary_data = UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]  # PNG header
        write(joinpath(dir, "image.png"), binary_data)

        router = Router()
        s = Server(router)
        mount!(s, dir)

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/image.png"; status_exception=false)
            @test resp.status == 200
            @test resp.body[1:8] == binary_data
        end
    end
end
