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

