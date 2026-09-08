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


@testset "Negotiation wildcards and q=0" begin
    app = App()
    get!(app, "/data") do req
        accept = context(req)[:accept]
        accept === Json ? json(Dict("json" => true)) :
        accept === Html ? html("<p>html</p>") :
        accept === Plain ? text("plain") : text("none")
    end
    use!(app, negotiate(formats=[Json, Html, Plain]))

    with_server(app) do port
        base = "http://127.0.0.1:$port/data"

        # Subtype wildcard text/* resolves to the first text format (Html).
        r = HTTP.get(base; headers=["Accept" => "text/*"], status_exception=false, retry=false)
        @test r.status == 200
        @test occursin("text/html", get(Dict(r.headers), "Content-Type", ""))

        # q=0 excludes a media range.
        r2 = HTTP.get(base; headers=["Accept" => "application/json;q=0, text/plain"],
                      status_exception=false, retry=false)
        @test String(r2.body) == "plain"

        # Explicit refusal of everything → server default (formats[1] = Json).
        r3 = HTTP.get(base; headers=["Accept" => "application/json;q=0, text/html;q=0, text/plain;q=0"],
                      status_exception=false, retry=false)
        @test r3.status == 200
        @test occursin("\"json\"", String(r3.body))
    end
end
