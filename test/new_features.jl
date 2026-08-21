"""
Tests for new v0.5.0 features: validation, typed services, content negotiation, security.
"""

@testset "Request Validation" begin
    struct TestUser
        name::String
        email::String
        age::Int
    end

    @testset "validate parses valid JSON body" begin
        req = Request(:post, "/users", "/users",
            Dict{String,String}(),
            Headers(["content-type" => "application/json"]),
            """{"name":"Alice","email":"alice@example.com","age":30}""")
        user = validate(req, TestUser)
        @test user.name == "Alice"
        @test user.email == "alice@example.com"
        @test user.age == 30
    end

    @testset "validate throws on empty body" begin
        req = Request(:post, "/users", "/users",
            Dict{String,String}(), Headers(), "")
        @test_throws ValidationError validate(req, TestUser)
    end

    @testset "validate throws on invalid JSON" begin
        req = Request(:post, "/users", "/users",
            Dict{String,String}(), Headers(), "not json{")
        @test_throws ValidationError validate(req, TestUser)
    end

    @testset "validate throws on missing field" begin
        req = Request(:post, "/users", "/users",
            Dict{String,String}(), Headers(),
            """{"name":"Alice","email":"alice@example.com"}""")
        @test_throws ValidationError validate(req, TestUser)
    end

    @testset "validate throws on wrong type" begin
        req = Request(:post, "/users", "/users",
            Dict{String,String}(), Headers(),
            """{"name":"Alice","email":"alice@example.com","age":"not a number"}""")
        @test_throws ValidationError validate(req, TestUser)
    end

    @testset "validate with error handler returns Response" begin
        req = Request(:post, "/users", "/users",
            Dict{String,String}(), Headers(), "")
        result = validate(req, TestUser) do err
            json(Dict("error" => err); status=422)
        end
        @test result isa Response
        @test result.status == 422
    end

    @testset "validate coerces Float to Int" begin
        struct IntHolder
            value::Int
        end
        req = Request(:post, "/", "/",
            Dict{String,String}(), Headers(),
            """{"value":42.0}""")
        h = validate(req, IntHolder)
        @test h.value == 42
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

@testset "Content Negotiation" begin
    @testset "negotiate middleware sets accept in context" begin
        app = App()
        use!(app, negotiate())

        get!(app, "/data") do req
            fmt = context(req)[:accept]
            if fmt === Json
                json(Dict("format" => "json"))
            else
                text("plain")
            end
        end

        client = Mongoose.TestClient(app)

        # JSON preferred
        resp = client(:get, "/data"; headers=["accept" => "application/json"])
        @test resp.status == 200
        @test contains(resp.body, "json")

        # Plain text preferred
        resp = client(:get, "/data"; headers=["accept" => "text/plain"])
        @test resp.status == 200
        @test resp.body == "plain"
    end

    @testset "negotiate defaults to first supported format" begin
        app = App()
        use!(app, negotiate(formats=[Html, Json]))

        get!(app, "/") do req
            fmt = context(req)[:accept]
            @test fmt === Html  # Default when no match
            text("ok")
        end

        client = Mongoose.TestClient(app)
        client(:get, "/"; headers=["accept" => "image/png"])
    end
end

@testset "ServerConfig" begin
    @testset "config stores tuning parameters" begin
        app = App(workers=2, max_body=1024, poll_timeout=5)
        @test app.workers == 2
        @test app.max_body == 1024
        @test app.poll_timeout == 5
        @test app.config isa Mongoose.ServerConfig
        @test app.config.workers == 2
    end

    @testset "config validates parameters" begin
        @test_throws Mongoose.ServerError App(max_body=0)
        @test_throws Mongoose.ServerError App(workers=-1)
        @test_throws Mongoose.ServerError App(poll_timeout=-1)
    end
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
