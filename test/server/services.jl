@testset "service!/inject" begin
    @testset "Service retrieved per request" begin
        s = App()
        service!(s, :version, "1.0.0")
        get!(s, "/version") do req
            v = service(req, :version)
            text("v=$v")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/version"; status_exception=false)
            @test String(resp.body) == "v=1.0.0"
        end
    end
end

@testset "Typed NamedTuple services" begin
    @testset "Val-typed access + missing service" begin
        s = App(services=(db="pool", retries=3))
        @test s.services.deps.db == "pool"
        get!(s, "/svc") do req
            db = service(req, Val(:db))       # type-stable access
            retries = service(req, Val(:retries))
            text("db=$db retries=$retries")
        end
        get!(s, "/missing") do req
            v = service(req, Val(:nope))
            text(v === nothing ? "none" : "got")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/svc"; status_exception=false)
            @test String(resp.body) == "db=pool retries=3"
            resp2 = HTTP.get("http://127.0.0.1:$port/missing"; status_exception=false)
            @test String(resp2.body) == "none"
        end
    end
end

@testset "Typed Services" begin
    @testset "service(req, name, T) returns typed value" begin
        app = App()
        service!(app, :version, "1.0.0")

        get!(app, "/test") do req
            v = service(req, :version, String)
            text(v)
        end

        client = Mongoose.TestClient(app)
        resp = client(:get, "/test")
        @test resp.status == 200
        @test resp.body == "1.0.0"
    end

    @testset "service(req, name, T) throws on type mismatch" begin
        app = App()
        service!(app, :count, 42)

        get!(app, "/test") do req
            service(req, :count, String)  # Wrong type
        end

        client = Mongoose.TestClient(app)
        resp = client(:get, "/test")
        @test resp.status == 500  # Handler throws TypeError
    end

    @testset "service(req, name, T) throws KeyError on missing" begin
        app = App()

        get!(app, "/test") do req
            service(req, :missing, String)
        end

        client = Mongoose.TestClient(app)
        resp = client(:get, "/test")
        @test resp.status == 500
    end
end

@testset "service!/inject integration" begin
    app = App()
    service!(app, :db, () -> "database_connection")
    get!(app, "/svc") do req
        db = service(req, :db)
        text(db)
    end

    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/svc"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "database_connection"
    end
end

