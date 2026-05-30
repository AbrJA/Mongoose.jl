@testset "WebSocket basic" begin
    @testset "Echo message" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/echo"; on_message=msg -> Message("Echo: $(msg.data)"))
        s = Async(router; nworkers=2)

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/echo") do ws
                HTTP.WebSockets.send(ws, "hello")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "Echo: hello"
            end
        end
    end

    @testset "Multiple messages" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/multi"; on_message=msg -> Message("Got: $(msg.data)"))
        s = Async(router; nworkers=2)

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
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/open";
            on_message=msg -> Message("ok"),
            on_open=(req) -> (opened[] = true))
        s = Async(router; nworkers=2)

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
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/close";
            on_message=msg -> Message("ok"),
            on_close=() -> (closed[] = true))
        s = Async(router; nworkers=2)

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

@testset "WebSocket with static router" begin
    @testset "@router WebSocket echo" begin
        s = Async(TestRoutes; nworkers=2)
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/chat") do ws
                HTTP.WebSockets.send(ws, "hello")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "Echo: hello"
            end
        end
    end
end

@testset "WebSocket special characters" begin
    @testset "Unicode messages" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/unicode"; on_message=msg -> Message(msg.data))
        s = Async(router; nworkers=2)

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/unicode") do ws
                text = "日本語テスト 🎉"
                HTTP.WebSockets.send(ws, text)
                resp = HTTP.WebSockets.receive(ws)
                @test String(resp) == text
            end
        end
    end

    @testset "Empty message" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/empty"; on_message=msg -> Message("len=$(length(msg.data))"))
        s = Async(router; nworkers=2)

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
    router = Router()
    route!(router, :get, "/", req -> Response(200, "", "ok"))
    ws!(router, "/ws/concurrent"; on_message=msg -> Message("Reply: $(msg.data)"))
    s = Async(router; nworkers=4)

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
