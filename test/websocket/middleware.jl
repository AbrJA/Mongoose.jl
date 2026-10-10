# WebSocket handshakes run through the middleware pipeline: global and
# path-scoped middleware (auth, ratelimit, logging…) observe the upgrade
# request; a short-circuiting Response aborts the handshake.

using Sockets

struct _DenyUpgrade <: Mongoose.AbstractMiddleware end
(_::_DenyUpgrade)(req, next) = throw(UnauthorizedError("upgrade denied"))

@testset "WS handshake middleware" begin
    @testset "API key protects the handshake" begin
        s = App(2)
        ws!(s, "/ws/secure"; on_message=msg -> Message("ok: $(msg.data)"))
        s = use(s, apikey("secret-key"))

        with_server(s) do port
            # A plain request to a WS path hits middleware first: no key → 401.
            r = HTTP.get("http://127.0.0.1:$port/ws/secure"; status_exception=false)
            @test r.status == 401
            # With the key but no upgrade headers, mongoose answers 426.
            r426 = HTTP.get("http://127.0.0.1:$port/ws/secure"; status_exception=false,
                            headers=["X-API-Key" => "secret-key"])
            @test r426.status == 426
            # With the key and a real upgrade, frames flow.
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/secure";
                                 headers=["X-API-Key" => "secret-key"]) do ws
                HTTP.WebSockets.send(ws, "hi")
                @test String(HTTP.WebSockets.receive(ws)) == "ok: hi"
            end
        end
    end

    @testset "Path-scoped middleware applies to WS only" begin
        s = App()
        route!(s, :get, "/open") do req; text("open") end
        ws!(s, "/ws/scoped"; on_message=msg -> Message("ok"))
        s = use(s, bearer("tok"); paths=["/ws"])

        with_server(s) do port
            @test HTTP.get("http://127.0.0.1:$port/open"; status_exception=false).status == 200
            @test HTTP.get("http://127.0.0.1:$port/ws/scoped"; status_exception=false).status == 401
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/scoped";
                                 headers=["Authorization" => "Bearer tok"]) do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "ok"
            end
        end
    end

    @testset "Middleware exception maps to its HTTP status" begin
        s = App()
        ws!(s, "/ws/deny"; on_message=msg -> Message("never"))
        s = use(s, _DenyUpgrade())
        with_server(s) do port
            r = HTTP.get("http://127.0.0.1:$port/ws/deny"; status_exception=false)
            @test r.status == 401
        end
    end

    @testset "on_open sees the pipeline request (DI services)" begin
        s = App()
        seen = Ref{Any}(nothing)
        ws!(s, "/ws/di";
            on_open=req -> (seen[] = service(req, Val(:db)); true),
            on_message=msg -> Message("ok"))
        s = provide(s, (db="pool",))
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/di") do ws
                HTTP.WebSockets.send(ws, "x")
                @test String(HTTP.WebSockets.receive(ws)) == "ok"
            end
        end
        @test seen[] == "pool"
    end

    @testset "on_open rejection still answers 403" begin
        s = App()
        ws!(s, "/ws/no"; on_message=msg -> Message("x"), on_open=req -> false)
        s = use(s, (req, next) -> next())   # pass-through middleware
        with_server(s) do port
            sock = Sockets.connect("127.0.0.1", port)
            write(sock, "GET /ws/no HTTP/1.1\r\nHost: x\r\n" *
                        "Connection: Upgrade\r\nUpgrade: websocket\r\n" *
                        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" *
                        "Sec-WebSocket-Version: 13\r\n\r\n")
            head = String(readuntil(sock, "\r\n\r\n"))
            @test startswith(head, "HTTP/1.1 403")
            close(sock)
        end
    end
end
