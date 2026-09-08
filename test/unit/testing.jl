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

