@testset "WebSocket basic" begin
    @testset "Echo message" begin
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/echo"; on_message=msg -> Message("Echo: $(msg.data)"))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/echo") do ws
                HTTP.WebSockets.send(ws, "hello")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "Echo: hello"
            end
        end
    end

    @testset "Multiple messages" begin
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/multi"; on_message=msg -> Message("Got: $(msg.data)"))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/multi") do ws
                for i in 1:5
                    HTTP.WebSockets.send(ws, "msg$i")
                    resp = HTTP.WebSockets.receive(ws)
                    @test String(resp) == "Got: msg$i"
                end
            end
        end
    end
end

@testset "WebSocket server-initiated push (broadcastws)" begin
    s = App(workers=2)
    get!(s, "/") do req; text("ok") end
    ws!(s, "/ws/push"; on_message=msg -> Message("reply: $(msg.data)"))

    with_server(s) do port
        HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/push") do ws
            sleep(0.4)                       # let the upgrade register in the loop
            Mongoose.broadcastws(s, "/ws/push", "server-push")
            @test String(HTTP.WebSockets.receive(ws)) == "server-push"

            # In-flight reply interleaving still works after a push.
            HTTP.WebSockets.send(ws, "ping")
            @test String(HTTP.WebSockets.receive(ws)) == "reply: ping"
        end
    end

    @testset "push targets only the matching path" begin
        s2 = App(workers=2)
        ws!(s2, "/a"; on_message=msg -> Message("a"))
        ws!(s2, "/b"; on_message=msg -> Message("b"))
        with_server(s2) do port
            ch = Channel{String}(1)
            # Client A stays open while we push to /b only.
            HTTP.WebSockets.open("ws://127.0.0.1:$port/a") do wa
                Mongoose.broadcastws(s2, "/b", "to-b")
                sleep(0.5)
                # A must NOT have received anything: prove it by round-tripping.
                HTTP.WebSockets.send(wa, "x")
                @test String(HTTP.WebSockets.receive(wa)) == "a"
            end
        end
    end
end

@testset "WebSocket lifecycle callbacks" begin
    @testset "on_open callback" begin
        opened = Channel{Nothing}(1)
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/open";
            on_message=msg -> Message("ok"),
            on_open=(req) -> signal(opened))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/open") do ws
                HTTP.WebSockets.send(ws, "ping")
                HTTP.WebSockets.receive(ws)
            end
            # The upgrade handshake is the sync; timedwait is only a hang-guard.
            @test timedwait(() -> isready(opened), 5.0; pollint=0.005) == :ok
        end
    end

    @testset "on_close callback" begin
        closed = Channel{Nothing}(1)
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/close";
            on_message=msg -> Message("ok"),
            on_close=() -> signal(closed))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/close") do ws
                HTTP.WebSockets.send(ws, "ping")
                HTTP.WebSockets.receive(ws)
            end
            # Deterministic: wait for the server-side on_close event (the
            # timedwait is only a hang-guard; the sync is the Channel).
            got_close = timedwait(() -> isready(closed), 5.0; pollint=0.005)
            @test got_close == :ok
        end
    end
end

@testset "WebSocket special characters" begin
    @testset "Unicode messages" begin
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/unicode"; on_message=msg -> Message(msg.data))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/unicode") do ws
                txt = "日本語テスト 🎉"
                HTTP.WebSockets.send(ws, txt)
                resp = HTTP.WebSockets.receive(ws)
                @test String(resp) == txt
            end
        end
    end

    @testset "Empty message" begin
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/empty"; on_message=msg -> Message("len=$(length(msg.data))"))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/empty") do ws
                HTTP.WebSockets.send(ws, "")
                resp = HTTP.WebSockets.receive(ws)
                @test String(resp) == "len=0"
            end
        end
    end
end

@testset "WebSocket concurrent connections" begin
    s = App(workers=4)
    get!(s, "/") do req; text("ok") end
    ws!(s, "/ws/concurrent"; on_message=msg -> Message("Reply: $(msg.data)"))

    with_server(s) do port
        tasks = [@async begin
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/concurrent") do ws
                HTTP.WebSockets.send(ws, "client$i")
                resp = HTTP.WebSockets.receive(ws)
                String(resp)
            end
        end for i in 1:5]

        results = fetch.(tasks)
        for i in 1:5
            @test results[i] == "Reply: client$i"
        end
    end
end

@testset "WS origin allowlist" begin
    s = App()
    ws!(s, "/ws/guard";
        on_message=msg -> Message("ok"),
        allowed_origins=["https://allowed.example"])

    with_server(s) do port
        # Disallowed (and absent) origins are rejected with 403 before upgrade.
        ok = try
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/guard";
                                 headers=["Origin" => "https://evil.example"]) do ws
                HTTP.WebSockets.receive(ws)
            end
            true
        catch
            false
        end
        @test ok == false
    end
end

@testset "WS upgrade guardrails" begin
    @testset "Non-upgrade request does not run on_open or register" begin
        s = App()
        opened = Ref(false)
        ws!(s, "/ws/hook";
            on_message=msg -> Message("x"),
            on_open=req -> (opened[] = true; true))

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ws/hook"; status_exception=false)
            @test resp.status == 426
            @test opened[] == false
            @test isempty(s.runtime.ws_clients)
        end
    end

    @testset "Idle timeout closes the client" begin
        # The sweep compares seconds against the *_ms config and must drop the
        # server-side registration (on_close + bookkeeping) for an idle client.
        # Client-side close-frame delivery depends on the peer's read loop, so
        # the assertion is on the server-observable contract.
        s = App(workers=2, ws_idle_timeout_ms=200)
        closed = Ref(false)
        ws!(s, "/ws/idle";
            on_message=msg -> Message("x"),
            on_close=() -> (closed[] = true))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/idle") do ws
                dropped = wait_until(timeout=6.0) do
                    isempty(s.runtime.ws_clients) && isempty(s.runtime.connections)
                end
                @test dropped
                @test closed[]
            end
        end
    end
end

using Sockets

# Minimal client-side WebSocket framing for control-frame tests (masked).
function _ws_client_frame(op::UInt8, payload::Vector{UInt8}=UInt8[])
    n = length(payload)
    io = IOBuffer()
    write(io, UInt8(0x80) | op)
    if n < 126
        write(io, UInt8(0x80) | UInt8(n))
    else
        write(io, UInt8(0x80) | UInt8(126))
        write(io, hton(UInt16(n)))
    end
    key = rand(UInt8, 4)
    write(io, key)
    for (i, c) in enumerate(payload)
        write(io, c ⊻ key[mod1(i, 4)])
    end
    return take!(io)
end

function _ws_read_frame(sock)
    b1 = read(sock, UInt8)
    b2 = read(sock, UInt8)
    op = b1 & 0x0F
    n = Int(b2 & 0x7F)
    if n == 126
        n = Int(ntoh(read(sock, UInt16)))
    elseif n == 127
        n = Int(ntoh(read(sock, UInt64)))
    end
    masked = (b2 & 0x80) != 0
    key = masked ? read(sock, 4) : UInt8[]
    data = read(sock, n)
    if masked
        data = UInt8[c ⊻ key[mod1(i, 4)] for (i, c) in enumerate(data)]
    end
    return op, data
end

@testset "Control frames are answered exactly once" begin
    # Regression: mongoose auto-replies to PING (PONG) and CLOSE (echo +
    # drain); the control handler must not reply a second time.
    s = App(workers=2)
    ws!(s, "/ws/ctl"; on_message=msg -> Message(msg.data))
    with_server(s) do port
        sock = Sockets.connect("127.0.0.1", port)
        write(sock, "GET /ws/ctl HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n" *
                    "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" *
                    "Sec-WebSocket-Version: 13\r\nOrigin: http://127.0.0.1\r\n\r\n")
        @test contains(readuntil(sock, "\r\n\r\n"), "101")

        write(sock, _ws_client_frame(0x09, Vector{UInt8}("ping")))
        op, data = _ws_read_frame(sock)
        @test op == 0x0A && String(data) == "ping"
        sleep(0.3)
        @test bytesavailable(sock) == 0          # no duplicate pong

        write(sock, _ws_client_frame(0x08, UInt8[0x03, 0xE8]))
        op, _ = _ws_read_frame(sock)
        @test op == 0x08
        sleep(0.3)
        @test bytesavailable(sock) == 0          # no duplicate close
        close(sock)
    end
end
