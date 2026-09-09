@testset "TestClient" begin
    app = App()
    get!(app, "/hello") do req
        text("Hello World")
    end
    get!(app, "/json") do req
        json((message="hi", count=42))
    end
    post!(app, "/echo") do req
        text("Got: $(req.body)")
    end
    get!(app, "/query") do req
        q = query(req, "name", "unknown")
        text("Hello $q")
    end

    client = Mongoose.TestClient(app)

    @testset "GET text response" begin
        resp = client(:get, "/hello")
        @test resp.status == 200
        @test resp.body == "Hello World"
    end

    @testset "GET JSON response" begin
        resp = client(:get, "/json")
        @test resp.status == 200
        @test contains(resp.body, "\"message\"")
        @test contains(resp.body, "\"hi\"")
    end

    @testset "POST with body" begin
        resp = client(:post, "/echo"; body="test data")
        @test resp.status == 200
        @test resp.body == "Got: test data"
    end

    @testset "Query parameters" begin
        resp = client(:get, "/query"; query=Dict("name" => "Julia"))
        @test resp.status == 200
        @test contains(resp.body, "Julia")
    end

    @testset "404 for missing route" begin
        resp = client(:get, "/nonexistent")
        @test resp.status == 404
    end

    @testset "405 for wrong method" begin
        resp = client(:post, "/hello")
        @test resp.status == 405
    end
end

@testset "HTTPError via TestClient" begin
    struct ErrUser
        name::String
        age::Int
    end

    app = App()
    get!(app, "/teapot") do req
        throw(ImATeapotError("short and stout"))
    end
    get!(app, "/gone") do req
        throw(NotFoundError("user 7 missing"))
    end
    get!(app, "/conflict") do req
        throw(ConflictError("duplicate email"))
    end
    post!(app, "/valid") do req
        validate(req, ErrUser)
    end
    post!(app, "/valid/json") do req
        json(validate(req, ErrUser))
    end

    client = Mongoose.TestClient(app)

    @testset "error_status / showerror on the types" begin
        e = NotFoundError("user 7 missing")
        @test Mongoose.error_status(e) == 404
        @test e isa Mongoose.HTTPError
        @test occursin("Not Found (404): user 7 missing", sprint(showerror, e))
        @test BadRequestError === HTTPError{400}
        @test occursin("Too Many Requests (429): slow down", sprint(showerror, TooManyRequestsError("slow down")))
    end

    @testset "automatic fallback to Response" begin
        r = client(:get, "/gone")
        @test r.status == 404
        @test r.body == "user 7 missing"
        @test get(r.headers, "content-type", "") == "text/plain"

        r = client(:get, "/conflict")
        @test r.status == 409

        r = client(:get, "/teapot")
        @test r.status == 418
        @test r.body == "short and stout"
    end

    @testset "ValidationError defaults to 422" begin
        r = client(:post, "/valid"; body="not json")
        @test r.status == 422
        r = client(:post, "/valid/json"; body=JSON.json(Dict("name" => "Alice")))
        @test r.status == 422
    end

    @testset "onerror! registration beats the automatic mapping" begin
        ae = App()
        get!(ae, "/g") do req; throw(NotFoundError("boom")) end
        onerror!(ae, NotFoundError) do req, e
            text("custom: $(e.message)"; status=404)
        end
        c = Mongoose.TestClient(ae)
        r = c(:get, "/g")
        @test r.status == 404
        @test r.body == "custom: boom"
    end
end

