@testset "Static Files" begin
    mktempdir() do dir
        write(joinpath(dir, "index.html"), "<h1>Home</h1>")
        write(joinpath(dir, "style.css"), "body { color: red; }")
        mkdir(joinpath(dir, "sub"))
        write(joinpath(dir, "sub", "page.html"), "<p>Sub</p>")

        router = Router()
        route!(router, :get, "/api/hello", (req) -> Response(200, "", "hello"))

        server = Server(router)
        mount!(server, dir)
        start!(server; port=8117, blocking=false)
        wait_for_server("http://localhost:8117/")

        try
            resp = HTTP.get("http://localhost:8117/")
            @test resp.status == 200
            @test String(resp.body) == "<h1>Home</h1>"

            resp = HTTP.get("http://localhost:8117/style.css")
            @test resp.status == 200
            @test String(resp.body) == "body { color: red; }"

            resp = HTTP.get("http://localhost:8117/sub/page.html")
            @test resp.status == 200
            @test String(resp.body) == "<p>Sub</p>"

            resp = HTTP.get("http://localhost:8117/missing.txt"; status_exception=false)
            @test resp.status == 404

            resp = HTTP.get("http://localhost:8117/../../../etc/passwd"; status_exception=false)
            @test resp.status in (403, 404)

            resp = HTTP.get("http://localhost:8117/api/hello")
            @test resp.status == 200
            @test String(resp.body) == "hello"
        finally
            shutdown!(server)
        end
    end
end

@testset "mount! with URI prefix" begin
    mktempdir() do dir
        write(joinpath(dir, "logo.txt"), "LOGO_DATA")
        mkdir(joinpath(dir, "sub"))
        write(joinpath(dir, "sub", "page.txt"), "SUB_PAGE")

        router = Router()
        route!(router, :get, "/api/ping", req -> Response(200, "", "pong"))
        server = Server(router)
        mount!(server, dir; uri_prefix="/static")
        start!(server; port=8208, blocking=false)
        wait_for_server("http://localhost:8208/")

        try
            resp = HTTP.get("http://localhost:8208/static/logo.txt")
            @test resp.status == 200
            @test String(resp.body) == "LOGO_DATA"

            resp = HTTP.get("http://localhost:8208/static/sub/page.txt")
            @test resp.status == 200
            @test String(resp.body) == "SUB_PAGE"

            resp = HTTP.get("http://localhost:8208/logo.txt"; status_exception=false)
            @test resp.status == 404

            resp = HTTP.get("http://localhost:8208/api/ping")
            @test resp.status == 200
            @test String(resp.body) == "pong"
        finally
            shutdown!(server)
        end
    end
end

@testset "mount! multiple static directories" begin
    mktempdir() do base
        dir_a = joinpath(base, "site")
        dir_b = joinpath(base, "assets")
        mkdir(dir_a)
        mkdir(dir_b)
        write(joinpath(dir_a, "index.html"), "<h1>Home</h1>")
        write(joinpath(dir_b, "app.js"),     "console.log(1)")

        router = Router()
        server = Server(router)
        mount!(server, dir_a)
        mount!(server, dir_b; uri_prefix="/assets")
        start!(server; port=8209, blocking=false)
        wait_for_server("http://localhost:8209/")

        try
            resp = HTTP.get("http://localhost:8209/")
            @test resp.status == 200
            @test String(resp.body) == "<h1>Home</h1>"

            resp = HTTP.get("http://localhost:8209/assets/app.js")
            @test resp.status == 200
            @test String(resp.body) == "console.log(1)"
        finally
            shutdown!(server)
        end
    end
end
