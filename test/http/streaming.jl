@testset "SSE streaming" begin
    @testset "Basic SSE response" begin
        s = App(workers=2)
        get!(s, "/events") do req
            sse(req) do writer
                emit(writer; data="hello", event="greeting")
                emit(writer; data="world", id="1")
            end
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "data: hello")
            @test contains(body, "event: greeting")
            @test contains(body, "data: world")
            @test contains(body, "id: 1")
            @test endswith(body, "\n\n")                       # terminated
            @test occursin("event: greeting", body) # order check
            idx_id  = findfirst("id: 1", body)
            idx_data = findfirst("data: world", body)
            @test idx_data !== nothing && idx_id !== nothing && idx_id < idx_data
        end
    end

    @testset "SSE framing (unit, via FakeTransport)" begin
        s = App()
        get!(s, "/events") do req
            sse(req) do writer
                emit(writer; data="line1\nline2", event="evt", id="7", retry_ms=1000)
                emit(writer; data="third")
            end
        end
        resp = FakeTransport(s)(:get, "/events")
        @test resp.status == 200
        body = String(resp.body)

        # Event 1: id/event/retry lines, multi-line data, blank-line end.
        @test startswith(body, "id: 7\nevent: evt\nretry: 1000\n")
        @test occursin("data: line1\ndata: line2\n\n", body)
        # Event 2: only data.
        @test endswith(body, "data: third\n\n")
        # Content-Type is the SSE media type.
        @test any(h -> h.first == "Content-Type" && h.second == "text/event-stream",
                  resp.headers)
        # Events are separated by exactly one blank line.
        @test occursin("data: line2\n\ndata: third", body)
    end

    @testset "Slow stream does not block the event loop" begin
        # Worst case: sync mode, single poll thread. A producer that sleeps
        # between events must not stall unrelated HTTP requests.
        #
        # Deterministic sync: the producer signals a Channel after its FIRST
        # emitted event, so the test knows the stream is genuinely mid-flight
        # (no fixed sleep to guess "the stream is halfway done").
        s = App()
        mid_stream = Channel{Nothing}(1)
        get!(s, "/events") do req
            sse(req) do writer
                emit(writer; data="tick 1")
                signal(mid_stream)   # mid-flight handshake (never blocks)
                for i in 2:5
                    emit(writer; data="tick $i")
                    sleep(0.3)
                end
            end
        end
        get!(s, "/fast") do req; text("ok") end

        with_server(s) do port
            # Warm the measured route (JIT) so timing measures the loop, not
            # the compiler. The producer is mid-flight when /events runs next.
            HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)

            slow = @async HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)

            # Block until the producer emitted its first event (hang-guard
            # timedwait; the sync itself is the Channel).
            got_mid = timedwait(() -> isready(mid_stream), 5.0; pollint=0.005)
            @test got_mid == :ok   # stream is mid-production, deterministically

            t0 = time()
            resp = HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)
            elapsed = time() - t0

            @test resp.status == 200
            @test String(resp.body) == "ok"
            @test elapsed < 0.5   # streaming path must not stall the loop
            fetch(slow)
        end
    end
end


@testset "shutdown drains active streams" begin
    finished = Ref(false)
    app = App(drain_timeout_ms=5000)
    get!(app, "/drain") do req
        sse(req) do writer
            for i in 1:5
                emit(writer; data="e$i")
                sleep(0.05)
            end
            finished[] = true
        end
    end

    port = fresh_port()
    start!(app; host="127.0.0.1", port=port, blocking=false)
    try
        wait_for_server("http://127.0.0.1:$port/")
        resp_task = @async HTTP.get("http://127.0.0.1:$port/drain"; status_exception=false)

        # Wait until the stream is registered, then shut down while it runs:
        # the drain must let the producer finish and deliver all events.
        started = wait_until(timeout=5.0) do
            !isempty(app.runtime.streams)
        end
        @test started
        shutdown!(app)

        @test finished[]
        resp = fetch(resp_task)
        @test contains(String(resp.body), "data: e5")
    finally
        shutdown!(app)
    end
end

@testset "slow consumer backpressure caps buffered bytes" begin
    cap = 64 * 1024
    s = App(workers=2, send_buffer_bytes=cap)
    get!(s, "/events") do req
        sse(req) do w
            for i in 1:20000
                emit(w; data="x"^1000)   # ~20MB: exceeds any kernel buffer
            end
        end
    end
    get!(s, "/ping") do req; text("pong") end

    with_server(s) do port
        sock = Sockets.connect("127.0.0.1", port)
        write(sock, "GET /events HTTP/1.1\r\nHost: x\r\n\r\n")
        readuntil(sock, "\r\n\r\n")     # response headers
        readavailable(sock)               # a few events
        sleep(1.0)                        # stop reading: producer hits the cap

        # Event loop stays responsive.
        t0 = time()
        r = HTTP.get("http://127.0.0.1:$port/ping"; status_exception=false, retry=false)
        @test r.status == 200
        @test time() - t0 < 1.0

        # The connection's unsent buffer is capped (one chunk of slack).
        @test length(s.runtime.streams) == 1
        st = first(values(s.runtime.streams))
        @test Mongoose._send_buffered(st.conn) <= cap + 64 * 1024
        @test isready(st.channel)         # producer parked on the bounded channel

        close(sock)
        @test wait_until(timeout=5.0) do
            isempty(s.runtime.streams)
        end
        @test HTTP.get("http://127.0.0.1:$port/ping"; status_exception=false,
                       retry=false).status == 200
    end
end
