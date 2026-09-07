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

@testset "WebSocket lifecycle callbacks" begin
    @testset "on_open callback" begin
        opened = Ref(false)
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/open";
            on_message=msg -> Message("ok"),
            on_open=(req) -> (opened[] = true))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/open") do ws
                HTTP.WebSockets.send(ws, "ping")
                HTTP.WebSockets.receive(ws)
            end
            sleep(0.1)
            @test opened[] == true
        end
    end

    @testset "on_close callback" begin
        closed = Ref(false)
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/close";
            on_message=msg -> Message("ok"),
            on_close=() -> (closed[] = true))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/close") do ws
                HTTP.WebSockets.send(ws, "ping")
                HTTP.WebSockets.receive(ws)
            end
            sleep(0.2)
            @test closed[] == true
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
