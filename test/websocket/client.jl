# WSClient: per-connection identity, state, DI access, and targeted send.
# (Sync mode is used where per-connection ordering must be deterministic;
# async workers may run frames from one connection concurrently.)

using Sockets

@testset "WSClient context" begin
    @testset "identity + isolated state (sync, ordered)" begin
        s = App()                          # sync: frames run inline, in order
        ws!(s, "/ws/count";
            on_open = (req, client) -> (client.state[:n] = 0; true),
            on_message = (msg, client) -> begin
                client.state[:n] += 1
                Message("n=$(client.state[:n])")
            end)
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/count") do wa
                HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/count") do wb
                    HTTP.WebSockets.send(wa, "x"); HTTP.WebSockets.send(wa, "x")
                    @test String(HTTP.WebSockets.receive(wa)) == "n=1"
                    @test String(HTTP.WebSockets.receive(wa)) == "n=2"
                    # The second connection starts from its own state.
                    HTTP.WebSockets.send(wb, "x")
                    @test String(HTTP.WebSockets.receive(wb)) == "n=1"
                end
            end
        end
    end

    @testset "distinct ids across connections (async)" begin
        s = App(2)
        opened = Channel{Int}(2)
        ws!(s, "/ws/id";
            on_open = (req, client) -> (put!(opened, client.id); true),
            on_message = (msg, client) -> Message("id=$(client.id)"))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/id") do wa
                HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/id") do wb
                    ida, idb = take!(opened), take!(opened)
                    @test ida != idb
                    HTTP.WebSockets.send(wa, "x")
                    @test String(HTTP.WebSockets.receive(wa)) == "id=$ida"
                    HTTP.WebSockets.send(wb, "x")
                    @test String(HTTP.WebSockets.receive(wb)) == "id=$idb"
                end
            end
        end
    end

    @testset "DI services via client.request" begin
        s = App()
        ws!(s, "/ws/di";
            on_message = (msg, client) -> Message(service(client.request, Val(:db))))
        s = provide(s, (db="pool",))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/di") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "pool"
            end
        end
    end

    @testset "on_close receives the populated state" begin
        s = App()
        at_close = Ref{Any}(nothing)
        ws!(s, "/ws/close";
            on_open = (req, client) -> (client.state[:n] = 7; true),
            on_message = (msg, client) -> Message("ok"),
            on_close = client -> (at_close[] = (client.id, client.state[:n])))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/close") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "ok"
            end
            wait_until(timeout=5.0) do
                at_close[] !== nothing
            end
        end
        @test at_close[] !== nothing
        @test at_close[][2] == 7
    end

    @testset "sendws targets one client (async)" begin
        s = App(2)
        opened = Channel{WSClient}(2)
        ws!(s, "/ws/target";
            on_open = (req, client) -> (put!(opened, client); true),
            on_message = (msg, client) -> Message("ack"))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/target") do wa
                ca = take!(opened)
                HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/target") do wb
                    cb = take!(opened)
                    @test ca.id != cb.id
                    sendws(s, cb, "to-b")
                    @test String(HTTP.WebSockets.receive(wb)) == "to-b"
                    # A must not receive it: prove with a round-trip.
                    HTTP.WebSockets.send(wa, "x")
                    @test String(HTTP.WebSockets.receive(wa)) == "ack"
                end
            end
        end
    end

    @testset "sendws from a sync handler" begin
        s = App()
        ws!(s, "/ws/sync";
            on_message = (msg, client) -> (sendws(s, client, "extra"); Message("ack")))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/sync") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "extra"
                @test String(HTTP.WebSockets.receive(ws)) == "ack"
            end
        end
    end

    @testset "StaticRouter WS receives the client" begin
        opened = Ref{Any}(nothing)
        router = @routes begin
            ws("/chat", (msg, client) -> Message("static: $(msg.data)");
               on_open = (req, client) -> (opened[] = client.id; true))
        end
        app = App(router=router)
        with_server(app) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/chat") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "static: x"
            end
        end
        @test opened[] isa Int
    end
end
