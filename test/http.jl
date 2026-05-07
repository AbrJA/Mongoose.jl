@testset "JSON Integration" begin
    router = Router()
    route!(router, :get, "/api/json", (req) -> Response(Json, Dict("message" => "hello", "count" => 42)))
    route!(router, :post, "/api/echo", (req) -> begin
        data = JSON.parse(req.body)
        Response(Json, data)
    end)

    server = Async(router; nworkers=1)
    start!(server, port=8097, blocking=false)
    wait_for_server("http://localhost:8097/")

    try
        response = HTTP.get("http://localhost:8097/api/json")
        @test response.status == 200
        headers_dict = Dict(String(h.first) => String(h.second) for h in response.headers)
        @test headers_dict["Content-Type"] == "application/json; charset=utf-8"
        body_str = String(response.body)
        @test occursin("hello", body_str)
        @test occursin("42", body_str)

        response = HTTP.post("http://localhost:8097/api/echo";
            headers=["Content-Type" => "application/json"],
            body="{\"key\":\"value\"}")
        @test response.status == 200
        @test occursin("value", String(response.body))
    finally
        shutdown!(server)
    end
end

@testset "Body Size Limit" begin
    router = Router()
    route!(router, :post, "/upload", (req) -> Response(200, "", "OK"))

    server = Async(router; nworkers=1, max_body=100)
    start!(server, port=8099, blocking=false)
    wait_for_server("http://localhost:8099/")

    try
        response = HTTP.post("http://localhost:8099/upload"; body="short")
        @test response.status == 200

        large_body = repeat("x", 200)
        response = HTTP.post("http://localhost:8099/upload"; body=large_body, status_exception=false)
        @test response.status == 413
    finally
        shutdown!(server)
    end
end

@testset "Header Handling" begin
    router = Router()
    route!(router, :get, "/headers", (req) -> begin
        user_agent = get(req.headers, "User-Agent", nothing)
        Response(200, "X-Custom: Received\r\n", "UA: $user_agent")
    end)

    server = Async(router; nworkers=1)
    start!(server; port=8109, blocking=false)
    wait_for_server("http://localhost:8109/")

    try
        resp = HTTP.get("http://localhost:8109/headers"; headers=["User-Agent" => "TestClient"])
        @test resp.status == 200
        @test String(resp.body) == "UA: TestClient"
        headers_dict = Dict(String(h.first) => String(h.second) for h in resp.headers)
        @test headers_dict["X-Custom"] == "Received"
    finally
        shutdown!(server)
    end
end

@testset "Binary Response Body" begin
    # Vector{UInt8} bodies must be delivered byte-exact, including null bytes.
    # mg_http_reply uses printf/strlen internally and would truncate at 0x00.
    # _send! builds a raw HTTP response buffer and writes it with mg_send.
    #
    # Use a real 1×1 red PNG (67 bytes) as the payload — it contains multiple
    # null bytes in IHDR/IDAT chunks, making it a realistic stress-test.
    red1x1_png = UInt8[
        # PNG signature
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        # IHDR: 1×1, 8-bit RGB
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xde,
        # IDAT: zlib-compressed red pixel
        0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x01, 0xe2, 0x21, 0xbc, 0x33,
        # IEND
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
        0xae, 0x42, 0x60, 0x82,
    ]

    router = Router()
    route!(router, :get, "/image.png", req -> Response(200, "Content-Type: image/png\r\n", red1x1_png))

    server = Server(router)
    start!(server; port=8130, blocking=false)
    wait_for_server("http://localhost:8130/")

    try
        resp = HTTP.get("http://localhost:8130/image.png")
        @test resp.status == 200
        @test resp.body == red1x1_png
        @test length(resp.body) == length(red1x1_png)

        arouter = Router()
        route!(arouter, :get, "/image.png", req -> Response(200, "Content-Type: image/png\r\n", red1x1_png))
        aserver = Async(arouter)
        start!(aserver; port=8131, blocking=false)
        wait_for_server("http://localhost:8131/")

        try
            resp2 = HTTP.get("http://localhost:8131/image.png")
            @test resp2.status == 200
            @test resp2.body == red1x1_png
        finally
            shutdown!(aserver)
        end
    finally
        shutdown!(server)
    end
end

@testset "Body Percent Sign" begin
    router = Router()
    route!(router, :get, "/pct", (req) -> Response(200, "", "100% done"))

    server = Server(router)
    start!(server; port=8118, blocking=false)
    wait_for_server("http://localhost:8118/")

    try
        resp = HTTP.get("http://localhost:8118/pct")
        @test resp.status == 200
        @test String(resp.body) == "100% done"
    finally
        shutdown!(server)
    end
end

@testset "Request Context" begin
    router = Router()
    route!(router, :get, "/ctx", (req) -> begin
        ctx = context!(req)
        @assert ctx isa Dict{Symbol,Any}
        ctx[:user] = "alice"
        Response(200, "", "user=$(ctx[:user])")
    end)

    server = Server(router)
    start!(server; port=8116, blocking=false)
    wait_for_server("http://localhost:8116/")

    try
        resp = HTTP.get("http://localhost:8116/ctx")
        @test resp.status == 200
        @test String(resp.body) == "user=alice"
    finally
        shutdown!(server)
    end
end

@testset "Custom fail! for 500 and 413" begin
    router = Router()
    route!(router, :get,  "/boom",   req -> error("deliberate crash"))
    route!(router, :post, "/upload", req -> Response(200, "", "ok"))

    server = Async(router; nworkers=1, max_body=50)
    fail!(server, 500, Response(Json, """{"error":"internal","code":500}"""; status=500))
    fail!(server, 413, Response(Json, """{"error":"too large","code":413}"""; status=413))
    start!(server; port=8206, blocking=false)
    wait_for_server("http://localhost:8206/")

    try
        resp = HTTP.get("http://localhost:8206/boom"; status_exception=false)
        @test resp.status == 500
        body = String(resp.body)
        @test occursin("internal", body)
        @test occursin("500",      body)

        resp = HTTP.post("http://localhost:8206/upload";
                         body=repeat("x", 100), status_exception=false)
        @test resp.status == 413
        body413 = String(resp.body)
        @test occursin("too large", body413)
    finally
        shutdown!(server)
    end
end

@testset "Async request_timeout → 504" begin
    router = Router()
    route!(router, :get, "/ping", req -> Response(200, "", "pong"))
    route!(router, :get, "/fast", req -> Response(200, "", "fast"))
    route!(router, :get, "/slow", req -> (sleep(5); Response(200, "", "never")))

    server = Async(router; nworkers=1, request_timeout=200)
    start!(server; port=8212, blocking=false)
    wait_for_server("http://localhost:8212/")

    # Warm up the JIT via a request that has no timing assertions.
    HTTP.get("http://localhost:8212/ping")
    sleep(0.1)

    try
        resp = HTTP.get("http://localhost:8212/fast")
        @test resp.status == 200
        @test String(resp.body) == "fast"

        resp = HTTP.get("http://localhost:8212/slow";
                        readtimeout=10, status_exception=false)
        @test resp.status == 504
    finally
        shutdown!(server)
    end
end

@testset "Unicode body round-trip" begin
    emoji_body = "Hello 🌍 from Mongoose.jl — café résumé"

    router = Router()
    route!(router, :get,  "/unicode", req -> Response(emoji_body))
    route!(router, :post, "/echo",    req -> Response(req.body))

    server = Server(router)
    start!(server; port=8224, blocking=false)
    wait_for_server("http://localhost:8224/")

    try
        resp = HTTP.get("http://localhost:8224/unicode")
        @test resp.status == 200
        @test String(resp.body) == emoji_body

        resp = HTTP.post("http://localhost:8224/echo"; body=emoji_body)
        @test resp.status == 200
        @test String(resp.body) == emoji_body
    finally
        shutdown!(server)
    end
end

@testset "X-Request-Id echoed in response" begin
    router = Router()
    route!(router, :get, "/id", req -> Response(200, "", "ok"))

    server = Server(router)
    start!(server; port=8225, blocking=false)
    wait_for_server("http://localhost:8225/")

    try
        resp = HTTP.get("http://localhost:8225/id";
                        headers=["X-Request-Id" => "req-abc-123"])
        @test resp.status == 200
        @test HTTP.header(resp, "X-Request-Id") == "req-abc-123"

        long_id = repeat("a", 64)
        resp = HTTP.get("http://localhost:8225/id";
                        headers=["X-Request-Id" => long_id])
        @test resp.status == 200
        @test HTTP.header(resp, "X-Request-Id") == long_id
    finally
        shutdown!(server)
    end
end

@testset "context! lazy allocation and isolation between requests" begin
    router = Router()
    route!(router, :get, "/ctx/:key", (req, key) -> begin
        ctx = context!(req)
        ctx[:val] = key
        Response(200, "", "$(ctx[:val])")
    end)

    server = Async(router; nworkers=2)
    start!(server; port=8223, blocking=false)
    wait_for_server("http://localhost:8223/")

    try
        results = Vector{String}(undef, 5)
        @sync for i in 1:5
            let i = i
                @async begin
                    resp = HTTP.get("http://localhost:8223/ctx/item$i")
                    results[i] = String(resp.body)
                end
            end
        end
        for i in 1:5
            @test results[i] == "item$i"
        end
    finally
        shutdown!(server)
    end
end
