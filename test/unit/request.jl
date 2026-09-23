@testset "Request constructors" begin
    @testset "Full constructor" begin
        req = Request(:get, "/test?q=1", "/test",
            Dict("q" => "1"),
            Headers(["content-type" => "text/plain"]),
            "")
        @test req.method == :get
        @test req.uri == "/test?q=1"
        @test req.path == "/test"
        @test req.query["q"] == "1"
        @test req.body == ""
    end

    @testset "Vector headers convenience" begin
        req = Request(:post, "/data", "/data",
            Dict{String,String}(),
            ["content-type" => "application/json"],
            """{"key":"val"}""")
        @test req.headers isa Headers
        @test get(req.headers, "content-type", "") == "application/json"
    end

    @testset "Auto-strip query" begin
        req = Request(:get, "/search?q=hello",
            Dict("q" => "hello"),
            Headers(),
            "")
        @test req.path == "/search"
    end

    @testset "remote_addr field" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        @test req.remote_addr === nothing          # default: transport-less
        req2 = Request(:get, "/", "/", Dict{String,String}(), Headers(), "",
            nothing, "10.0.0.9")
        @test req2.remote_addr == "10.0.0.9"
    end
end

@testset "Headers" begin
    @testset "Empty headers" begin
        h = Headers()
        @test isempty(h)
        @test length(h) == 0
    end

    @testset "Get with case insensitivity" begin
        h = Headers(["content-type" => "text/html", "x-custom" => "value"])
        @test get(h, "content-type", "") == "text/html"
        @test get(h, "Content-Type", "") == "text/html"
        @test get(h, "CONTENT-TYPE", "") == "text/html"
    end

    @testset "haskey" begin
        h = Headers(["authorization" => "Bearer token"])
        @test haskey(h, "authorization")
        @test haskey(h, "Authorization")
        @test !haskey(h, "x-missing")
    end

    @testset "Default value for missing key" begin
        h = Headers(["a" => "1"])
        @test get(h, "b", "default") == "default"
    end

    @testset "Iteration" begin
        pairs = ["a" => "1", "b" => "2"]
        h = Headers(pairs)
        collected = collect(h)
        @test length(collected) == 2
    end
end

@testset "Header normalization (asheaders + Headers constructors)" begin
    h = Headers(["a" => "1"])
    @test Mongoose.asheaders(h) === h
    @test Mongoose.asheaders("a" => "1").data == ["a" => "1"]
    @test Mongoose.asheaders(("a" => "1", "b" => "2")).data == ["a" => "1", "b" => "2"]
    @test Mongoose.asheaders([("a" => "1")]).data == ["a" => "1"]
    @test isempty(Mongoose.asheaders(String[]).data)
    @test isempty(Mongoose.asheaders(nothing).data)

    # String-ish pair entries are converted, not rejected.
    ss = SubString("abc", 1, 1)
    @test Mongoose.asheaders([ss => ss]).data == ["a" => "a"]
    @test_throws ArgumentError Mongoose.asheaders(["not a pair"])

    # Constructors: pair / tuple / empty-untyped vector.
    @test Headers("a" => "1").data == ["a" => "1"]
    @test Headers(("a" => "1", "b" => "2")).data == ["a" => "1", "b" => "2"]
    @test isempty(Headers([]))
end

@testset "Request header inputs" begin
    req = Request(:get, "/", "/", Dict{String,String}(), ("x-a" => "1",), "")
    @test get(req.headers, "x-a", "") == "1"
    req2 = Request(:get, "/", Dict{String,String}(), Headers(["x-b" => "2"]), "")
    @test get(req2.headers, "x-b", "") == "2"
end

@testset "Context" begin
    @testset "context() creates dict lazily" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        @test req.context === nothing
        c = context(req)
        @test c isa Dict{Symbol,Any}
        @test req.context !== nothing
    end

    @testset "context() returns same dict" begin
        req = Request(:get, "/", "/", Dict{String,String}(), Headers(), "")
        c1 = context(req)
        c1[:key] = "value"
        c2 = context(req)
        @test c1 === c2
        @test c2[:key] == "value"
    end
end

@testset "Query parameter helpers" begin
    @testset "String query param" begin
        req = Request(:get, "/search?q=hello&page=2", "/search",
            Dict("q" => "hello", "page" => "2"), Headers(), "")
        @test query(req, "q") == "hello"
        @test query(req, "missing") === nothing
        @test query(req, "q", "") == "hello"
        @test query(req, "missing", "default") == "default"
    end

    @testset "Integer query param" begin
        req = Request(:get, "/list?page=3&limit=50", "/list",
            Dict("page" => "3", "limit" => "50"), Headers(), "")
        @test query(req, "page", 1) == 3
        @test query(req, "limit", 20) == 50
        @test query(req, "offset", 0) == 0
    end

    @testset "Invalid integer returns default" begin
        req = Request(:get, "/list?page=abc", "/list",
            Dict("page" => "abc"), Headers(), "")
        @test query(req, "page", 1) == 1
    end

    @testset "Float query param" begin
        req = Request(:get, "/calc?rate=3.14", "/calc",
            Dict("rate" => "3.14"), Headers(), "")
        @test query(req, "rate", 0.0) ≈ 3.14
        @test query(req, "missing", 1.0) == 1.0
    end

    @testset "Bool query param" begin
        req = Request(:get, "/flags?debug=true&verbose=1&off=false", "/flags",
            Dict("debug" => "true", "verbose" => "1", "off" => "false"), Headers(), "")
        @test query(req, "debug", false) == true
        @test query(req, "verbose", false) == true
        @test query(req, "off", true) == false
        @test query(req, "missing", false) == false
    end
end

@testset "Body parsing helpers" begin
    @testset "body(req) returns raw body" begin
        req = Request(:post, "/data", "/data",
            Dict{String,String}(), Headers(), "raw body content")
        @test body(req) == "raw body content"
    end
end

@testset "JSON integration" begin
    @testset "json() with Dict" begin
        resp = json(Dict("key" => "value"))
        @test resp.status == 200
        @test contains(resp.body, "\"key\"")
        @test contains(resp.body, "\"value\"")
        @test any(p -> contains(p.second, "application/json"), resp.headers)
    end

    @testset "json() with NamedTuple" begin
        resp = json((id=1, name="test"))
        @test resp.status == 200
        @test contains(resp.body, "\"id\"")
        @test contains(resp.body, "\"name\"")
    end

    @testset "json() with custom status" begin
        resp = json(Dict("error" => "not found"); status=404)
        @test resp.status == 404
    end

    @testset "parsejson(req) parses body" begin
        req = Request(:post, "/", "/",
            Dict{String,String}(),
            Headers(["content-type" => "application/json"]),
            """{"hello":"world"}""")
        data = parsejson(req)
        @test data["hello"] == "world"
    end

    @testset "json(req) fails loudly (moved to parsejson)" begin
        req = Request(:post, "/", "/", Dict{String,String}(), Headers(), "{}")
        @test_throws ArgumentError json(req)
    end
end

@testset "Multipart parsing" begin
    @testset "Parse simple multipart" begin
        boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
        body_content = "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" *
            "Content-Disposition: form-data; name=\"field1\"\r\n\r\n" *
            "value1\r\n" *
            "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" *
            "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" *
            "Content-Type: text/plain\r\n\r\n" *
            "file content here\r\n" *
            "------WebKitFormBoundary7MA4YWxkTrZu0gW--"
        req = Request(:post, "/upload", "/upload",
            Dict{String,String}(),
            Headers(["content-type" => "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"]),
            body_content)
        parts = multipart(req)
        @test parts["field1"] == "value1"
        @test parts["file"] isa MultipartFile
        @test parts["file"].filename == "test.txt"
        @test parts["file"].content_type == "text/plain"
        @test String(parts["file"].data) == "file content here"
    end

    @testset "Wrong content type throws" begin
        req = Request(:post, "/upload", "/upload",
            Dict{String,String}(),
            Headers(["content-type" => "application/json"]),
            "{}")
        @test_throws UnsupportedMediaTypeError multipart(req)
    end
end


@testset "Chunked body decoding (RFC 9112 §7.1)" begin
    import Mongoose.Kernel: decode_chunked, decode_path_segment

    env = @__MODULE__  # module so struct types resolve below

    @testset "Basic framing" begin
        @test decode_chunked("6\r\nchunky\r\n0\r\n\r\n") == "chunky"
        @test decode_chunked("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n") == "Wikipedia"
    end
    @testset "Extensions + trailers" begin
        @test decode_chunked("4;ext=1\r\nWiki\r\n0;done\r\nX-Trailer: yes\r\n\r\n") == "Wiki"
    end
    @testset "Multi-chunk with embedded CRLF" begin
        @test decode_chunked("4\r\nA\r\nB\r\n0\r\n\r\n") == "A\r\nB"
    end
    @testset "Malformed framing passes through untouched" begin
        @test decode_chunked("not chunked at all") == "not chunked at all"
        @test decode_chunked("ff\r\ntoomuch\r\n0\r\n\r\n") == "ff\r\ntoomuch\r\n0\r\n\r\n"
    end
    @testset "Empty" begin
        @test decode_chunked("0\r\n\r\n") == ""
    end
    @testset "Path segment decoding (RFC 3986; '+' literal)" begin
        @test decode_path_segment("john%20doe") == "john doe"
        @test decode_path_segment("a+b") == "a+b"
        @test decode_path_segment("plain") == "plain"
        @test decode_path_segment("caf%C3%A9") == "café"
    end
end

@testset "Headers: mutation + Response integration" begin
    @testset "push!/append!/copy/getindex" begin
        h = Headers(["a" => "1"])
        push!(h, "B" => "2")
        append!(h, ["C" => "3", "D" => "4"])
        @test length(h) == 4
        @test h[2] == ("B" => "2")
        c = copy(h)
        @test c isa Headers && length(c) == 4
    end

    @testset "Response.headers is a Headers value" begin
        r = Response(200, ["Content-Type" => "text/plain"], "hi")
        @test r.headers isa Headers
        @test get(r.headers, "content-type", "") == "text/plain"
        @test r.headers["Content-Type"] == "text/plain"   # dict-style (case-insensitive)
        push!(r.headers, "X-Tag" => "v")
        @test get(r.headers, "x-tag", "") == "v"
        # vector constructor still works
        r2 = Response(404, Pair{String,String}["X-A" => "b"], "")
        @test r2.headers isa Headers
        @test get(r2.headers, "x-a", "") == "b"
    end

    @testset "StreamResponse.headers is a Headers value" begin
        sr = StreamResponse(w -> nothing, 200; content_type="text/event-stream",
            headers=["Cache-Control" => "no-cache"])
        @test sr.headers isa Headers
        @test length(sr.headers) == 1
        @test get(sr.headers, "cache-control", "") == "no-cache"
    end
end
