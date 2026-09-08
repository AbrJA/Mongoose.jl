@testset "WebSocket edge cases" begin
    @testset "on_close callback" begin
        closed = Ref(false)
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/close";
            on_message=msg -> Message("ack"),
            on_close=() -> (closed[] = true))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/close") do ws
                HTTP.WebSockets.send(ws, "hi")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "ack"
            end
            sleep(0.2)
            @test closed[]
        end
    end

    @testset "on_open with request info" begin
        captured_uri = Ref("")
        s = App(workers=2)
        get!(s, "/") do req; text("ok") end
        ws!(s, "/ws/open";
            on_open=req -> (captured_uri[] = req.uri; true),
            on_message=msg -> Message("ok"))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/open") do ws
                HTTP.WebSockets.send(ws, "test")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "ok"
            end
            sleep(0.1)
            @test contains(captured_uri[], "/ws/open")
        end
    end
end
