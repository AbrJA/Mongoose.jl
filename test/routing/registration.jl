@testset "Router construction" begin
    r = Router()
    @test r isa Router
    @test isempty(r.fixed)
    @test isempty(r.ws_routes)
end

@testset "Route registration" begin
    @testset "Fixed routes" begin
        r = Router()
        route!(r, :get, "/", req -> text("root"))
        route!(r, :post, "/data", req -> text("posted"))
        @test haskey(r.fixed, "/")
        @test haskey(r.fixed, "/data")
    end

    @testset "All HTTP methods" begin
        r = Router()
        for method in [:get, :post, :put, :patch, :delete, :options, :head]
            route!(r, method, "/test", req -> text(""))
        end
        @test r.fixed["/test"].handlers.get !== nothing
        @test r.fixed["/test"].handlers.post !== nothing
        @test r.fixed["/test"].handlers.put !== nothing
        @test r.fixed["/test"].handlers.patch !== nothing
        @test r.fixed["/test"].handlers.delete !== nothing
        @test r.fixed["/test"].handlers.options !== nothing
        @test r.fixed["/test"].handlers.head !== nothing
    end

    @testset "String method names" begin
        r = Router()
        route!(r, "GET", "/str", req -> text(""))
        @test haskey(r.fixed, "/str")
    end

    @testset "Invalid method" begin
        r = Router()
        @test_throws RouteError route!(r, :invalid, "/bad", req -> text(""))
    end

    @testset "Unknown parameter type" begin
        r = Router()
        err = try
            route!(r, :get, "/u/:id::UUID", req -> text(""))
        catch e
            e
        end
        @test err isa RouteError
        @test occursin("unknown route parameter type", err.msg)
        @test occursin("Int", err.msg)             # lists the supported names
        @test_throws RouteError route!(r, :get, "/u/:id::NotAType", req -> text(""))
        # The @routes macro path must reject the same typo.
        @test_throws LoadError @eval @routes begin
            get("/u/:id::UUID", req -> text(""))
        end
    end

    @testset "Parametric routes" begin
        r = Router()
        route!(r, :get, "/users/:id::Int", (req, id) -> text("user $id"))
        route!(r, :get, "/posts/:slug", (req, slug) -> text("post $slug"))
        @test !haskey(r.fixed, "/users/:id::Int")
    end

    @testset "Wildcard routes" begin
        r = Router()
        route!(r, :get, "/*path", (req, path) -> text(path))
        @test !haskey(r.fixed, "/*path")
    end
end

