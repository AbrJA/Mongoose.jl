@testset "Path-scoped middleware" begin
    s = App()
    get!(s, "/public") do req; text("public") end
    get!(s, "/admin/panel") do req; text("admin") end
    use!(s, bearer(t -> t == "secret"); paths=["/admin"])

    with_server(s) do port
        resp = HTTP.get("http://127.0.0.1:$port/public"; status_exception=false)
        @test resp.status == 200

        resp2 = HTTP.get("http://127.0.0.1:$port/admin/panel"; status_exception=false)
        @test resp2.status == 401

        resp3 = HTTP.get("http://127.0.0.1:$port/admin/panel";
            status_exception=false,
            headers=["Authorization" => "Bearer secret"])
        @test resp3.status == 200
    end
end

@testset "use! paths= input forms" begin
    for paths in ("/admin", ("/admin",), ["/admin"], [SubString("/admin/x", 1, 6)])
        app = App()
        get!(app, "/public") do req; text("public") end
        get!(app, "/admin/panel") do req; text("admin") end
        use!(app, bearer(t -> t == "secret"); paths=paths)
        client = Mongoose.FakeTransport(app)
        @test client(:get, "/public").status == 200
        @test client(:get, "/admin/panel").status == 401
        @test client(:get, "/admin/panel"; headers=["Authorization" => "Bearer secret"]).status == 200
    end
end

@testset "path prefixes match whole segments" begin
    app = App()
    get!(app, "/api/users") do req; text("users") end
    get!(app, "/apixyz") do req; text("other") end
    use!(app, bearer(t -> t == "s"); paths=["/api"])
    client = Mongoose.FakeTransport(app)
    @test client(:get, "/api/users").status == 401
    @test client(:get, "/apixyz").status == 200

    # Trailing slashes are normalized; "/" (or empty) means no filter.
    app2 = App()
    get!(app2, "/api/users") do req; text("users") end
    use!(app2, bearer(t -> t == "s"); paths=["/api/"])
    @test Mongoose.FakeTransport(app2)(:get, "/api/users").status == 401

    app3 = App()
    get!(app3, "/api/users") do req; text("users") end
    use!(app3, bearer(t -> t == "s"); paths=["/"])
    @test Mongoose.FakeTransport(app3)(:get, "/api/users").status == 401
end
