# Parametric WebSocket routes: typed path captures delivered to callbacks as
# client.params (a NamedTuple), dynamic Router and StaticRouter alike. A
# capture that fails to parse is "no WS match" (the request falls through to
# the HTTP pipeline).

using Sockets

@testset "Parametric WS routes" begin
    @testset "dynamic Router: typed params in all callbacks" begin
        s = App()
        opened = Channel{Any}(1)
        closed = Ref{Any}(nothing)
        ws!(s, "/rooms/:id::Int";
            on_open = (req, client) -> (put!(opened, client.params); true),
            on_message = (msg, client) -> Message("room=$(client.params.id):$(msg.data)"),
            on_close = client -> (closed[] = client.params))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/rooms/42") do ws
                HTTP.WebSockets.send(ws, "hi")
                @test String(HTTP.WebSockets.receive(ws)) == "room=42:hi"
            end
            wait_until(timeout=5.0) do
                closed[] !== nothing
            end
        end
        params = take!(opened)
        @test params.id == 42
        @test params.id isa Int
        @test closed[].id == 42
    end

    @testset "dynamic Router: string + wildcard captures" begin
        s = App()
        ws!(s, "/u/:name"; on_message=(msg, client) -> Message("hi $(client.params.name)"))
        ws!(s, "/files/*rest"; on_message=(msg, client) -> Message("file $(client.params.rest)"))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/u/ada") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "hi ada"
            end
            HTTP.WebSockets.open("ws://127.0.0.1:$port/files/a/b/c") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "file a/b/c"
            end
        end
    end

    @testset "StaticRouter: typed params via @routes" begin
        router = @routes begin
            ws("/rooms/:id::Int", (msg, client) -> Message("static room=$(client.params.id)");
               on_open = (req, client) -> true)
        end
        app = App(router=router)
        with_server(app) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/rooms/7") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "static room=7"
            end
        end
    end

    @testset "unparseable capture falls through to HTTP (404)" begin
        s = App()
        ws!(s, "/rooms/:id::Int"; on_message=(msg, client) -> Message("n"))
        with_server(s) do port
            r = HTTP.get("http://127.0.0.1:$port/rooms/abc"; status_exception=false)
            @test r.status == 404
        end
    end

    @testset "exact routes win over patterns" begin
        s = App()
        ws!(s, "/rooms/:id::Int"; on_message=(msg, client) -> Message("param"))
        ws!(s, "/rooms/new"; on_message=(msg, client) -> Message("exact"))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/rooms/new") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "exact"
            end
        end
    end

    @testset "broadcastws to a concrete parametric uri" begin
        s = App(2)
        ws!(s, "/rooms/:id::Int"; on_message=(msg, client) -> Message("ack"))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/rooms/5") do ws
                sleep(0.4)
                broadcastws(s, "/rooms/5", "push")
                @test String(HTTP.WebSockets.receive(ws)) == "push"
            end
        end
    end
end
