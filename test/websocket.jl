@testset "WebSocket Tests" begin
    router = Router()
    ws!(router, "/chat", on_message=function (msg::Message)
            if msg.data isa String
                println("Server received text: ", msg.data)
                return Message("Echo: " * msg.data)
            else
                println("Server received binary of length: ", length(msg.data))
                return Message(msg.data)
            end
        end, on_open=function (req::Request)
            println("Server opened WS connection! Headers: ", req.headers)
        end, on_close=function ()
            println("Server closed WS connection!")
        end)

    server = Async(router, nworkers=1)
    start!(server, port=8098, blocking=false)
    wait_for_server("http://localhost:8098/")

    try
        HTTP.WebSockets.open("ws://localhost:8098/chat") do ws
            HTTP.WebSockets.send(ws, "Hello WebSockets!")
            response = HTTP.WebSockets.receive(ws)
            @test String(response) == "Echo: Hello WebSockets!"

            HTTP.WebSockets.send(ws, UInt8[1, 2, 3])
            response = HTTP.WebSockets.receive(ws)
            @test response == UInt8[1, 2, 3]
        end
    finally
        shutdown!(server)
    end
end

@testset "WebSocket on_open and on_close callbacks" begin
    open_fired  = Ref(false)
    close_fired = Ref(false)

    router = Router()
    ws!(router, "/lifecycle";
        on_message = (msg)  -> Message("echo: $(msg.data)"),
        on_open    = (req)  -> (open_fired[]  = true),
        on_close   = ()     -> (close_fired[] = true))

    server = Async(router; nworkers=1)
    start!(server; port=8213, blocking=false)
    wait_for_server("http://localhost:8213/")

    try
        HTTP.WebSockets.open("ws://localhost:8213/lifecycle") do ws
            HTTP.WebSockets.send(ws, "hello")
            reply = String(HTTP.WebSockets.receive(ws))
            @test reply == "echo: hello"
            @test open_fired[]
        end
        sleep(0.2)
        @test close_fired[]
    finally
        shutdown!(server)
    end
end

@testset "WebSocket concurrent connections" begin
    router = Router()
    ws!(router, "/concurrent";
        on_message = (msg) -> Message("reply: $(msg.data)"))

    server = Async(router; nworkers=2)
    start!(server; port=8214, blocking=false)
    wait_for_server("http://localhost:8214/")

    try
        results = Channel{String}(6)
        @sync for i in 1:3
            let i = i
                @async begin
                    HTTP.WebSockets.open("ws://localhost:8214/concurrent") do ws
                        HTTP.WebSockets.send(ws, "client$i")
                        put!(results, String(HTTP.WebSockets.receive(ws)))
                    end
                end
            end
        end
        collected = [take!(results) for _ in 1:3]
        @test length(collected) == 3
        @test all(startswith(m, "reply: client") for m in collected)
    finally
        shutdown!(server)
    end
end

@testset "WebSocket graceful close" begin
    router = Router()
    ws!(router, "/wsclose",
        on_message = (msg) -> Message("reply: $(msg.data)"))

    server = Server(router)
    start!(server; port=8226, blocking=false)
    wait_for_server("http://localhost:8226/")

    try
        HTTP.WebSockets.open("ws://localhost:8226/wsclose") do ws
            HTTP.WebSockets.send(ws, "test")
            reply = String(HTTP.WebSockets.receive(ws))
            @test reply == "reply: test"
        end
    finally
        shutdown!(server)
    end
end

@testset "WS upgrade rejection: on_open returns false → 403" begin
    router = Router()
    route!(router, :get, "/", req -> Response(Plain, "ok"))

    ws!(router, "/ws/reject",
        on_message = (msg::Message) -> Message("echo"),
        on_open    = (req::Request) -> false,
    )

    ws!(router, "/ws/accept",
        on_message = (msg::Message) -> Message("accepted"),
        on_open    = (req::Request) -> true,
    )

    server = Async(router; nworkers=1)
    start!(server; port=8227, blocking=false)
    wait_for_server("http://localhost:8227/")

    try
        resp = HTTP.get("http://localhost:8227/ws/reject";
            headers=["Upgrade" => "websocket", "Connection" => "Upgrade",
                     "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==",
                     "Sec-WebSocket-Version" => "13"],
            status_exception=false)
        @test resp.status == 403

        HTTP.WebSockets.open("ws://localhost:8227/ws/accept") do ws
            HTTP.WebSockets.send(ws, "hello")
            reply = String(HTTP.WebSockets.receive(ws))
            @test reply == "accepted"
        end
    finally
        shutdown!(server)
    end
end

@testset "WebSocket idle timeout closes stale connection" begin
    router = Router()
    close_count = Threads.Atomic{Int}(0)
    route!(router, :get, "/", req -> Response(Plain, "ok"))
    ws!(router, "/idle",
        on_message = (msg::Message) -> Message("echo"),
        on_open    = (req::Request) -> nothing,
        on_close   = () -> Threads.atomic_add!(close_count, 1)
    )

    # ws_idle_timeout=1 means connections idle >1s are eligible for close.
    # The event loop sweeps every 5s, so the close arrives within ~6s.
    server = Server(router; ws_idle_timeout=1)
    start!(server; port=8234, blocking=false)
    wait_for_server("http://localhost:8234/")

    try
        client_observed_close = Ref(false)
        unexpected_client_error = Ref{Any}(nothing)
        client_task = @async begin
            try
                HTTP.WebSockets.open("ws://localhost:8234/idle") do ws
                    try
                        HTTP.WebSockets.receive(ws)
                        client_observed_close[] = true
                    catch
                        client_observed_close[] = true
                    end
                end
                client_observed_close[] = true
            catch e
                unexpected_client_error[] = e
            end
        end

        deadline = time() + 10.0
        while close_count[] == 0 && time() < deadline
            sleep(0.2)
        end

        client_deadline = time() + 5.0
        while !istaskdone(client_task) && time() < client_deadline
            sleep(0.05)
        end

        @test close_count[] >= 1
        @test client_observed_close[] == true
        @test unexpected_client_error[] === nothing
        @test istaskdone(client_task)
        wait(client_task)
    finally
        shutdown!(server)
    end
end
