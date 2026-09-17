import Base64
@testset "Bearer auth" begin
    @testset "Valid token passes" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> token == "valid-token"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure";
                status_exception=false,
                headers=["Authorization" => "Bearer valid-token"])
            @test resp.status == 200
            @test String(resp.body) == "secret"
        end
    end

    @testset "Missing auth header returns 401" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> token == "valid-token"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure"; status_exception=false)
            @test resp.status == 401
        end
    end

    @testset "Invalid token returns 403" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> token == "valid-token"))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure";
                status_exception=false,
                headers=["Authorization" => "Bearer wrong-token"])
            @test resp.status == 403
        end
    end

    @testset "Invalid scheme returns 401" begin
        s = App()
        get!(s, "/secure") do req; text("secret") end
        use!(s, bearer(token -> true))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/secure";
                status_exception=false,
                headers=["Authorization" => "Basic abc123"])
            @test resp.status == 401
        end
    end
end

@testset "API Key auth" begin
    @testset "Valid key passes" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, apikey(keys=Set(["key-123", "key-456"])))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api";
                status_exception=false,
                headers=["X-API-Key" => "key-123"])
            @test resp.status == 200
        end
    end

    @testset "Missing key returns 401" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, apikey(keys=Set(["key-123"])))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api"; status_exception=false)
            @test resp.status == 401
        end
    end

    @testset "Invalid key returns 401" begin
        s = App()
        get!(s, "/api") do req; text("data") end
        use!(s, apikey(keys=Set(["key-123"])))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api";
                status_exception=false,
                headers=["X-API-Key" => "wrong-key"])
            @test resp.status == 401
        end
    end
end

@testset "apikey builder forms" begin
    # Positional and keyword builders are equivalent; keys may be a single
    # string, a Set, or a Vector (normalized to Set{String}).
    for mw in (apikey("key-123"),
               apikey(Set(["key-123"])),
               apikey(["key-123"]),
               apikey(keys="key-123"),
               apikey(keys=Set(["key-123"])),
               apikey(keys=["key-123"]))
        app = App()
        use!(app, mw)
        get!(app, "/") do req; text("ok") end
        client = Mongoose.TestClient(app)
        @test client(:get, "/"; headers=["x-api-key" => "key-123"]).status == 200
        @test client(:get, "/"; headers=["x-api-key" => "wrong"]).status == 401
    end

    # Custom header name on the positional form.
    app = App()
    use!(app, apikey("key-123"; header_name="X-Api-Token"))
    get!(app, "/") do req; text("ok") end
    client = Mongoose.TestClient(app)
    @test client(:get, "/"; headers=["x-api-token" => "key-123"]).status == 200
    @test client(:get, "/"; headers=["x-api-key" => "key-123"]).status == 401
end

@testset "Constant-Time Auth" begin
    @testset "bearer with string uses constant-time comparison" begin
        app = App()
        use!(app, bearer("secret-token-123"))
        get!(app, "/") do req; text("ok") end

        client = Mongoose.TestClient(app)

        # Valid token
        resp = client(:get, "/"; headers=["authorization" => "Bearer secret-token-123"])
        @test resp.status == 200

        # Invalid token
        resp = client(:get, "/"; headers=["authorization" => "Bearer wrong-token"])
        @test resp.status == 403

        # Missing header
        resp = client(:get, "/")
        @test resp.status == 401
    end

    @testset "apikey uses constant-time comparison" begin
        app = App()
        use!(app, apikey(keys=Set(["key-abc-123"])))
        get!(app, "/") do req; text("ok") end

        client = Mongoose.TestClient(app)

        resp = client(:get, "/"; headers=["x-api-key" => "key-abc-123"])
        @test resp.status == 200

        resp = client(:get, "/"; headers=["x-api-key" => "wrong-key"])
        @test resp.status == 401
    end
end

@testset "Basic auth" begin
    app = App()
    get!(app, "/secure") do req
        text("secret data")
    end
    use!(app, basicauth("admin", "hunter2"))

    with_server(app) do port
        base = "http://127.0.0.1:$port"

        # No credentials → 401 with WWW-Authenticate.
        nogood = HTTP.get("$base/secure"; status_exception=false, retry=false)
        @test nogood.status == 401
        @test any(h -> lowercase(h.first) == "www-authenticate" && occursin("Basic", h.second), nogood.headers)

        # Wrong password → 401.
        bad = HTTP.get("$base/secure";
                       headers=["Authorization" => "Basic " * Base64.base64encode("admin:wrong")],
                       status_exception=false, retry=false)
        @test bad.status == 401

        # Correct credentials → 200.
        ok = HTTP.get("$base/secure";
                      headers=["Authorization" => "Basic " * Base64.base64encode("admin:hunter2")],
                      status_exception=false, retry=false)
        @test ok.status == 200
        @test String(ok.body) == "secret data"
    end
end
