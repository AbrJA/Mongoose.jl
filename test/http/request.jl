@testset "Request features" begin
    @testset "Headers are case-insensitive" begin
        s = App()
        get!(s, "/headers") do req
            val = header(req, "x-custom-header")
            text(isnothing(val) ? "missing" : val)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/headers";
                status_exception=false,
                headers=["X-Custom-Header" => "hello"])
            @test String(resp.body) == "hello"
        end
    end

    @testset "Context per request" begin
        s = App()
        get!(s, "/ctx") do req
            c = context(req)
            c[:user_id] = 42
            uid = c[:user_id]
            text("uid=$uid")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ctx"; status_exception=false)
            @test String(resp.body) == "uid=42"
        end
    end

    @testset "Query parameters parsed" begin
        s = App()
        get!(s, "/q") do req
            a = get(req.query, "a", "")
            b = get(req.query, "b", "")
            text("$a,$b")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?a=1&b=hello"; status_exception=false)
            @test String(resp.body) == "1,hello"
        end
    end

    @testset "Remote address from the C connection" begin
        s = App()
        get!(s, "/remote") do req
            addr = req.remote_addr
            text(isnothing(addr) ? "none" : addr)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/remote"; status_exception=false)
            # Loopback client: the peer IP is the machine's own loopback.
            @test occursin("127.0.0.1", String(resp.body))
        end
    end

    @testset "Chunked request body (RFC 9112 §7.1)" begin
        # Regression: the adapter used to re-decode Mongoose's already-decoded
        # body via an unbound name, so every chunked request hung.
        s = App()
        post!(s, "/chunked") do req
            text("len=$(length(req.body)):$(req.body)")
        end
        with_server(s) do port
            # An IO body with no Content-Length makes HTTP.jl use chunked TE.
            resp = HTTP.request("POST", "http://127.0.0.1:$port/chunked";
                body=IOBuffer("hello chunked"), status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "len=13:hello chunked"
        end
    end

    @testset "Chunked payload that looks chunked is not double-decoded" begin
        s = App()
        post!(s, "/chunked2") do req
            text(req.body)
        end
        with_server(s) do port
            payload = "5\r\nhello\r\n0\r\n\r\n"
            resp = HTTP.request("POST", "http://127.0.0.1:$port/chunked2";
                body=IOBuffer(payload), status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == payload
        end
    end
end

