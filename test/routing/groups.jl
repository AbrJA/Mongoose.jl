@testset "Route groups via mount!" begin
    @testset "Basic route group" begin
        s = App()
        grp = group("/api/v1")
        get!(grp, "/users") do req; text("users") end
        post!(grp, "/users") do req; Response(201, "created") end
        get!(grp, "/health") do req; text("ok") end
        mount!(s, grp)

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v1/users"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "users"

            resp = HTTP.post("http://127.0.0.1:$port/api/v1/users"; status_exception=false, body="")
            @test resp.status == 201

            resp = HTTP.get("http://127.0.0.1:$port/api/v1/health"; status_exception=false)
            @test String(resp.body) == "ok"
        end
    end
end

@testset "Route groups" begin
    @testset "Basic group via mount!" begin
        app = App()
        grp = group("/api/v1")
        get!(grp, "/users") do req; text("users list") end
        get!(grp, "/items") do req; text("items list") end
        @test mount!(app, grp) === app

        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v1/users"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "users list"

            resp2 = HTTP.get("http://127.0.0.1:$port/api/v1/items"; status_exception=false)
            @test resp2.status == 200
            @test String(resp2.body) == "items list"
        end
    end

    @testset "group middleware= input forms" begin
        for mws in (cors(), (cors(),), [cors()])
            app = App()
            grp = group("/api"; middleware=mws) do g
                get!(g, "/x", req -> text("x"))
            end
            @test mount!(app, grp) === app
            resp = Mongoose.TestClient(app)(:get, "/api/x"; headers=["Origin" => "https://a.test"])
            @test get(resp.headers, "access-control-allow-origin", nothing) == "*"
        end
    end
end

