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

