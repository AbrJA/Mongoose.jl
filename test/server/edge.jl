using Sockets

@testset "App lifecycle edge cases" begin
    @testset "Double start is no-op" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        port = fresh_port()
        start!(s; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
            start!(s; host="127.0.0.1", port=port+1, blocking=false)  # no-op
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
        finally
            shutdown!(s)
            sleep(0.05)
        end
    end

    @testset "Double shutdown is safe" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        port = fresh_port()
        start!(s; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
        finally
            shutdown!(s)
            sleep(0.05)
            shutdown!(s)  # second shutdown should not throw
        end
    end

    @testset "BindError on port in use" begin
        s1 = App()
        s2 = App()
        get!(s1, "/") do req; text("ok") end
        get!(s2, "/") do req; text("ok") end
        port = fresh_port()
        start!(s1; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
            @test_throws BindError start!(s2; host="127.0.0.1", port=port, blocking=false)
        finally
            shutdown!(s1)
            sleep(0.05)
        end
    end

    @testset "App validation" begin
        @test_throws ServerError App(max_body_bytes=0)
        @test_throws ServerError App(max_body_bytes=-1)
        @test_throws ServerError App(poll_timeout_ms=-1)
        @test_throws ServerError App(workers=-1)
    end

    @testset "Async App basic request" begin
        s = App(workers=2)
        get!(s, "/") do req; text("async-ok") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "async-ok"
        end
    end

    @testset "Async App concurrent requests" begin
        s = App(workers=4)
        get!(s, "/slow") do req
            sleep(0.05)
            text("done")
        end
        with_server(s) do port
            tasks = [@async HTTP.get("http://127.0.0.1:$port/slow"; status_exception=false) for _ in 1:4]
            results = [fetch(t) for t in tasks]
            @test all(r -> r.status == 200, results)
            @test all(r -> String(r.body) == "done", results)
        end
    end
end


@testset "Registration is rejected after start!" begin
    s = App()
    get!(s, "/before", req -> text("ok"))
    with_server(s) do port
        @test_throws Mongoose.ServerError get!(s, "/late", req -> text("x"))
        @test_throws Mongoose.ServerError route!(s, :get, "/late2", req -> text("x"))
        @test_throws Mongoose.ServerError use!(s, cors())
        @test_throws Mongoose.ServerError onerror!(s, 404, req -> text("x"))
        @test_throws Mongoose.ServerError ws!(s, "/ws"; on_message=req -> nothing)
        # pre-start registration still fine
        @test HTTP.get("http://127.0.0.1:$port/before"; status_exception=false).status == 200
    end
end

@testset "max_connections refuses extra connections" begin
    gate = Channel{Nothing}(2)
    app = App(workers=2, max_connections=2)
    get!(app, "/hold") do req
        sse(req) do w
            emit(w; data="open")
            take!(gate)
        end
    end
    get!(app, "/ping") do req; text("pong") end

    with_server(app) do port
        t1 = @async HTTP.get("http://127.0.0.1:$port/hold"; status_exception=false,
                             retry=false, read_idle_timeout=30)
        t2 = @async HTTP.get("http://127.0.0.1:$port/hold"; status_exception=false,
                             retry=false, read_idle_timeout=30)
        held = wait_until(timeout=5.0) do
            length(app.runtime.conn_times) >= 2
        end
        @test held

        refused = try
            HTTP.get("http://127.0.0.1:$port/hold"; status_exception=false,
                     retry=false, read_idle_timeout=3)
            false
        catch
            true
        end
        @test refused

        put!(gate, nothing)
        put!(gate, nothing)
        for t in (t1, t2)
            timedwait(() -> istaskdone(t), 10.0; pollint=0.05)
        end
        # Regression: refused connections must not leak fds or epoll entries
        # (mg_error path); the server keeps serving afterwards.
        r = HTTP.get("http://127.0.0.1:$port/ping"; status_exception=false,
                     retry=false, read_idle_timeout=3)
        @test r.status == 200
    end
end

@testset "header_timeout closes idle connections" begin
    app = App(header_timeout_ms=200)
    get!(app, "/") do req; text("ok") end

    with_server(app) do port
        sock = Sockets.connect("127.0.0.1", port)
        opened = wait_until(timeout=3.0) do
            !isempty(app.runtime.awaiting_headers)
        end
        @test opened
        closed = wait_until(timeout=6.0) do
            isempty(app.runtime.awaiting_headers)
        end
        @test closed
        # Regression: the sweep must actually close the TCP socket. The old
        # `mg_close_conn` path leaked the fd and left a dangling epoll
        # registration, which wedged the event loop for later requests.
        eof_task = @async eof(sock)
        @test timedwait(() -> istaskdone(eof_task), 3.0; pollint=0.05) == :ok
        @test istaskdone(eof_task) && fetch(eof_task) === true
        close(sock)
        r = HTTP.get("http://127.0.0.1:$port/"; status_exception=false, retry=false)
        @test r.status == 200
    end
end

@testset "header_timeout does not kill slow request bodies" begin
    app = App(header_timeout_ms=200)
    post!(app, "/echo") do req; text("len=$(sizeof(body(req)))") end

    with_server(app) do port
        sock = Sockets.connect("127.0.0.1", port)
        body = "x"^100
        write(sock, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nConnection: close\r\n\r\n")
        sleep(0.6)                    # longer than header_timeout_ms, headers done
        write(sock, body)
        task = @async String(read(sock))
        @test timedwait(() -> istaskdone(task), 5.0; pollint=0.05) == :ok
        resp = istaskdone(task) ? fetch(task) : ""
        istaskdone(task) || close(sock)
        @test contains(resp, "200 OK")
        @test contains(resp, "len=100")
        close(sock)
    end
end

@testset "body_timeout closes stalled uploads" begin
    app = App(workers=2, body_timeout_ms=300)
    get!(app, "/ping") do req; text("pong") end
    post!(app, "/echo") do req; text("len=$(sizeof(body(req)))") end

    with_server(app) do port
        # A body that never completes is reclaimed after the timeout.
        sock = Sockets.connect("127.0.0.1", port)
        write(sock, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nx")
        eof_task = @async eof(sock)
        @test timedwait(() -> istaskdone(eof_task), 6.0; pollint=0.05) == :ok
        @test istaskdone(eof_task) && fetch(eof_task) === true
        close(sock)

        # A body that completes within the timeout is served.
        sock2 = Sockets.connect("127.0.0.1", port)
        write(sock2, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\n")
        sleep(0.15)                      # below body_timeout_ms
        write(sock2, "hello")
        task = @async String(read(sock2))
        @test timedwait(() -> istaskdone(task), 5.0; pollint=0.05) == :ok
        resp = istaskdone(task) ? fetch(task) : ""
        istaskdone(task) || close(sock2)
        @test contains(resp, "200 OK")
        @test contains(resp, "len=5")
        close(sock2)

        @test HTTP.get("http://127.0.0.1:$port/ping"; status_exception=false,
                       retry=false).status == 200
    end
end

@testset "max_header_bytes caps request headers" begin
    app = App(max_header_bytes=1024)
    get!(app, "/ping") do req; text("pong") end

    with_server(app) do port
        @test HTTP.get("http://127.0.0.1:$port/ping"; status_exception=false,
                       retry=false).status == 200

        # Complete-but-oversized headers → clean 431.
        sock = Sockets.connect("127.0.0.1", port)
        write(sock, "GET /ping HTTP/1.1\r\nHost: x\r\nX-Big: " * "A"^2000 * "\r\n\r\n")
        task = @async readline(sock)
        @test timedwait(() -> istaskdone(task), 5.0; pollint=0.05) == :ok
        line = istaskdone(task) ? fetch(task) : ""
        istaskdone(task) || close(sock)
        @test contains(line, "431")
        close(sock)

        # Incomplete oversized headers → dropped before buffering more.
        sock2 = Sockets.connect("127.0.0.1", port)
        write(sock2, "GET /ping HTTP/1.1\r\nHost: x\r\nX-Big: " * "A"^2000)
        eof_task = @async eof(sock2)
        @test timedwait(() -> istaskdone(eof_task), 5.0; pollint=0.05) == :ok
        @test istaskdone(eof_task) && fetch(eof_task) === true
        close(sock2)

        @test HTTP.get("http://127.0.0.1:$port/ping"; status_exception=false,
                       retry=false).status == 200
    end
end
