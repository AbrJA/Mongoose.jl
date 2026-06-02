@testset "Static file serving" begin
    mktempdir() do dir
        write(joinpath(dir, "index.html"), "<html><body>Hello</body></html>")
        write(joinpath(dir, "style.css"), "body { color: red; }")
        write(joinpath(dir, "app.js"), "console.log('hello');")
        write(joinpath(dir, "data.json"), """{"key":"value"}""")
        write(joinpath(dir, "readme.txt"), "A plain text file")

        mkdir(joinpath(dir, "sub"))
        write(joinpath(dir, "sub", "nested.html"), "<p>nested</p>")

        @testset "Serves HTML file" begin
            s = App()
            get!(s, "/api") do req; text("api") end
            serve!(s, "/", dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/index.html"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "<html>")
            end
        end

        @testset "Serves CSS file" begin
            s = App()
            serve!(s, "/", dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/style.css"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "color: red")
            end
        end

        @testset "Serves JS file" begin
            s = App()
            serve!(s, "/", dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/app.js"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "console.log")
            end
        end

        @testset "Serves nested files" begin
            s = App()
            serve!(s, "/", dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/sub/nested.html"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "nested")
            end
        end

        @testset "Returns 404 for missing file" begin
            s = App()
            serve!(s, "/", dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/nonexistent.txt"; status_exception=false)
                @test resp.status == 404
            end
        end

        @testset "API routes coexist with static files" begin
            s = App()
            get!(s, "/api/data") do req; json("""{"api":true}""") end
            serve!(s, "/", dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/api/data"; status_exception=false)
                @test resp.status == 200
                @test JSON.parse(String(resp.body))["api"] == true

                resp2 = HTTP.get("http://127.0.0.1:$port/readme.txt"; status_exception=false)
                @test resp2.status == 200
                @test String(resp2.body) == "A plain text file"
            end
        end

        @testset "serve! with custom prefix" begin
            s = App()
            serve!(s, "/static", dir)

            with_server(s) do port
                resp = HTTP.get("http://127.0.0.1:$port/static/index.html"; status_exception=false)
                @test resp.status == 200
                @test contains(String(resp.body), "<html>")
            end
        end
    end
end

@testset "serve! validation" begin
    @test_throws ArgumentError serve!(App(), "/", "/nonexistent/path/xyz")
end

@testset "Binary file serving" begin
    mktempdir() do dir
        binary_data = UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]  # PNG header
        write(joinpath(dir, "image.png"), binary_data)

        s = App()
        serve!(s, "/", dir)

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/image.png"; status_exception=false)
            @test resp.status == 200
            @test resp.body[1:8] == binary_data
        end
    end
end
