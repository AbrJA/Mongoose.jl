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
            a = get(parsequery(req), "a", "")
            b = get(parsequery(req), "b", "")
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


@testset "Async Connection: close stays usable (client closes)" begin
    # The framework no longer writes mongoose connection state: a pool reply
    # cannot flush-and-close asynchronously through the public API, so the
    # header is not echoed and the client closes its side (it asked to).
    s = App(workers=2)
    get!(s, "/close") do req; text("bye") end
    with_server(s) do port
        sock = Sockets.connect("127.0.0.1", port)
        write(sock, "GET /close HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        head = readuntil(sock, "\r\n\r\n")
        @test contains(head, "200 OK")
        @test !contains(lowercase(head), "connection: close")
        len = parse(Int, match(r"content-length: (\d+)"i, head).captures[1])
        @test String(read(sock, len)) == "bye"
        close(sock)
    end
end

@testset "Oversized body rejected (413) after buffering" begin
    s = App(max_body_bytes=1024)
    post!(s, "/echo") do req; text("got") end
    with_server(s) do port
        # Early rejection is gone: mongoose buffers the body (bounded by its
        # 8 MiB ceiling) and the message-complete path answers 413.
        r = HTTP.post("http://127.0.0.1:$port/echo"; body=repeat("x", 4096),
                      status_exception=false, retry=false)
        @test r.status == 413
        @test HTTP.get("http://127.0.0.1:$port/echo"; status_exception=false,
                       retry=false).status == 405     # server healthy
    end
end

@testset "CL+TE request smuggling is dropped" begin
    s = App()
    post!(s, "/echo") do req; text("len=$(sizeof(body(req)))") end
    with_server(s) do port
        # Both framing headers present: the connection is dropped (there is no
        # public API to send a response and close cleanly).
        sock = Sockets.connect("127.0.0.1", port)
        write(sock, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n" *
                    "Transfer-Encoding: chunked\r\n\r\n6\r\nhello!\r\n0\r\n\r\n")
        drained = @async read(sock)
        @test timedwait(() -> istaskdone(drained), 3.0; pollint=0.05) == :ok
        @test istaskdone(drained) && isempty(fetch(drained))
        close(sock)

        # Plain chunked still works.
        sock2 = Sockets.connect("127.0.0.1", port)
        write(sock2, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n" *
                     "Connection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
        resp = String(read(sock2))
        @test contains(resp, "200 OK")
        @test contains(resp, "len=5")
        close(sock2)
    end
end
