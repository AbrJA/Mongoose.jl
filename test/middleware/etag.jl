@testset "ETag + conditional requests" begin
    app = App()
    get!(app, "/res") do req
        json((id=1, name="Alice"))
    end
    route!(app, :post, "/res", req -> json((id=1, name="Alice")))
    get!(app, "/empty") do req; Response(204, Pair{String,String}[], "") end
    get!(app, "/raw") do req; "plain" end
    get!(app, "/pre") do req
        Response(200, ["etag" => "\"custom\""], "x")
    end
    use!(app, etag())
    client = Mongoose.TestClient(app)

    @testset "ETag generation" begin
        r = client(:get, "/res")
        @test r.status == 200
        tag = get(r.headers, "etag", "")
        @test startswith(tag, "\"") && endswith(tag, "\"") && length(tag) == 18  # "hex16"
        # Stable across requests.
        r2 = client(:get, "/res")
        @test get(r2.headers, "etag", "") == tag
    end

    @testset "If-None-Match: 304 on match, 200 on mismatch" begin
        tag = get(client(:get, "/res").headers, "etag", "")

        r = client(:get, "/res"; headers=["If-None-Match" => tag])
        @test r.status == 304
        @test isempty(r.body)
        @test get(r.headers, "etag", "") == tag

        r = client(:get, "/res"; headers=["If-None-Match" => "\"bogus\""])
        @test r.status == 200

        # "*" matches any current representation.
        r = client(:get, "/res"; headers=["If-None-Match" => "*"])
        @test r.status == 304

        # Weak comparison: W/ prefix is stripped.
        r = client(:get, "/res"; headers=["If-None-Match" => "W/" * tag])
        @test r.status == 304

        # Non-GET/HEAD with matching If-None-Match → 412 (do not perform).
        r = client(:post, "/res"; headers=["If-None-Match" => tag])
        @test r.status == 412
    end

    @testset "If-Match: 412 on mismatch, pass on match" begin
        tag = get(client(:get, "/res").headers, "etag", "")
        r = client(:get, "/res"; headers=["If-Match" => "\"nope\""])
        @test r.status == 412
        r = client(:get, "/res"; headers=["If-Match" => tag])
        @test r.status == 200
        r = client(:get, "/res"; headers=["If-Match" => "*"])
        @test r.status == 200
    end

    @testset "Skipped responses" begin
        r = client(:get, "/empty")          # 204 → no body, no etag
        @test r.status == 204
        @test get(r.headers, "etag", "") == ""

        r = client(:get, "/raw")            # raw return: serialized after the pipeline
        @test r.status == 200
        @test get(r.headers, "etag", "") == ""

        r = client(:get, "/pre")            # existing ETag is kept untouched
        @test get(r.headers, "etag", "") == "\"custom\""
    end
end

@testset "ETag on the wire (live server)" begin
    s = App()
    get!(s, "/data") do req
        text("etag me")
    end
    get!(s, "/get-only") do req
        text("no head here")
    end
    # HEAD must be registered explicitly (no auto-HEAD fallback); mirroring
    # the GET body means it validates the same representation.
    head!(s, "/data") do req
        text("etag me")
    end
    use!(s, etag())
    with_server(s) do port
        r = HTTP.get("http://127.0.0.1:$port/data"; status_exception=false)
        @test r.status == 200
        tag = HTTP.header(r, "ETag")
        @test startswith(tag, "\"")

        r2 = HTTP.get("http://127.0.0.1:$port/data"; status_exception=false,
                      headers=["If-None-Match" => tag])
        @test r2.status == 304
        @test isempty(r2.body)
        @test HTTP.header(r2, "ETag") == tag

        # HEAD: same ETag as the GET (identical body), no body on the wire,
        # mongoose-native Content-Length (0 on a HEAD).
        r3 = HTTP.head("http://127.0.0.1:$port/data"; status_exception=false)
        @test r3.status == 200
        @test isempty(r3.body)
        @test HTTP.header(r3, "ETag") == tag
        @test HTTP.header(r3, "Content-Length") == "0"

        # A GET-only route answers 405 on HEAD, with Allow naming GET only.
        r4 = HTTP.head("http://127.0.0.1:$port/get-only"; status_exception=false)
        @test r4.status == 405
        @test occursin("GET", HTTP.header(r4, "Allow"))
        @test !occursin("HEAD", HTTP.header(r4, "Allow"))
    end
end

@testset "HEAD through compress + etag (live; explicit head! route)" begin
    s = App()
    get!(s, "/payload") do req
        text(repeat("All partial functions are structured transformations. ", 20))
    end
    head!(s, "/payload") do req
        text(repeat("All partial functions are structured transformations. ", 20))
    end
    use!(s, etag())          # registered outside compress: hashes wire bytes
    use!(s, compress(min_size=64))
    with_server(s) do port
        # Fresh connection per probe (HTTP.jl gzip pooling wedges otherwise).
        g = HTTP.get("http://127.0.0.1:$port/payload"; status_exception=false,
                     headers=["Accept-Encoding" => "gzip", "Connection" => "close"],
                     decompress=false)
        @test HTTP.header(g, "Content-Encoding") == "gzip"
        @test HTTP.header(g, "ETag") != ""

        # HEAD with gzip: the representation headers (encoding + etag) survive
        # the transport's body strip; no body on the wire.
        h = HTTP.head("http://127.0.0.1:$port/payload"; status_exception=false,
                      headers=["Accept-Encoding" => "gzip", "Connection" => "close"])
        @test h.status == 200
        @test isempty(h.body)
        @test HTTP.header(h, "Content-Encoding") == "gzip"
        @test HTTP.header(h, "ETag") == HTTP.header(g, "ETag")
    end
end