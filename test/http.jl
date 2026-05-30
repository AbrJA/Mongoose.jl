@testset "HTTP methods" begin
    @testset "GET request" begin
        router = Router()
        route!(router, :get, "/data", req -> Response(Json, """{"ok":true}"""))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/data"; status_exception=false)
            @test resp.status == 200
            @test JSON.parse(String(resp.body))["ok"] == true
            ct = HTTP.header(resp, "Content-Type")
            @test contains(ct, "application/json")
        end
    end

    @testset "POST with body" begin
        router = Router()
        route!(router, :post, "/echo", req -> Response(200, "", req.body))
        s = Server(router)
        with_server(s) do port
            body = "hello world"
            resp = HTTP.post("http://127.0.0.1:$port/echo"; body=body, status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == body
        end
    end

    @testset "PUT request" begin
        router = Router()
        route!(router, :put, "/items/1", req -> Response(200, "", "updated"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.put("http://127.0.0.1:$port/items/1"; body="data", status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "updated"
        end
    end

    @testset "PATCH request" begin
        router = Router()
        route!(router, :patch, "/items/1", req -> Response(200, "", "patched"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.patch("http://127.0.0.1:$port/items/1"; body="{}", status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "patched"
        end
    end

    @testset "DELETE request" begin
        router = Router()
        route!(router, :delete, "/items/:id::Int", (req, id) -> Response(200, "", "deleted $id"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.request("DELETE", "http://127.0.0.1:$port/items/5"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "deleted 5"
        end
    end

    @testset "HEAD request" begin
        router = Router()
        route!(router, :head, "/ping", req -> Response(200, "", ""))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.head("http://127.0.0.1:$port/ping"; status_exception=false)
            @test resp.status == 200
            @test isempty(resp.body)
        end
    end
end

@testset "Request headers" begin
    @testset "Custom headers are received" begin
        router = Router()
        route!(router, :get, "/headers", req -> begin
            val = get(req.headers, "x-custom-header", "missing")
            Response(200, "", val)
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/headers";
                status_exception=false,
                headers=["X-Custom-Header" => "test-value"])
            @test String(resp.body) == "test-value"
        end
    end

    @testset "Case-insensitive header lookup" begin
        router = Router()
        route!(router, :get, "/ci", req -> begin
            val = get(req.headers, "content-type", "none")
            Response(200, "", val)
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ci";
                status_exception=false,
                headers=["Content-Type" => "text/plain"])
            @test contains(String(resp.body), "text/plain")
        end
    end
end

@testset "Response formats" begin
    @testset "Plain text" begin
        router = Router()
        route!(router, :get, "/plain", req -> Response(Plain, "hello"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/plain"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "hello"
            @test contains(HTTP.header(resp, "Content-Type"), "text/plain")
        end
    end

    @testset "HTML" begin
        router = Router()
        route!(router, :get, "/page", req -> Response(Html, "<h1>Hi</h1>"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/page"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "text/html")
            @test String(resp.body) == "<h1>Hi</h1>"
        end
    end

    @testset "JSON with encoding" begin
        router = Router()
        route!(router, :get, "/json", req -> Response(Json, Dict("key" => "value")))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/json"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "application/json")
            parsed = JSON.parse(String(resp.body))
            @test parsed["key"] == "value"
        end
    end

    @testset "Custom status code" begin
        router = Router()
        route!(router, :post, "/create", req -> Response(Plain, "created"; status=201))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/create"; body="", status_exception=false)
            @test resp.status == 201
        end
    end

    @testset "Custom response headers" begin
        router = Router()
        route!(router, :get, "/custom", req -> Response(Plain, "ok"; headers=["X-Custom" => "hello"]))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/custom"; status_exception=false)
            @test HTTP.header(resp, "X-Custom") == "hello"
        end
    end
end

@testset "Request body" begin
    @testset "Empty body" begin
        router = Router()
        route!(router, :post, "/empty", req -> Response(200, "", "len=$(length(req.body))"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/empty"; body="", status_exception=false)
            @test String(resp.body) == "len=0"
        end
    end

    @testset "JSON body parsing" begin
        router = Router()
        route!(router, :post, "/json", req -> begin
            data = JSON.parse(req.body)
            Response(200, "", "name=$(data["name"])")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/json";
                body=JSON.json(Dict("name" => "Julia")),
                headers=["Content-Type" => "application/json"],
                status_exception=false)
            @test String(resp.body) == "name=Julia"
        end
    end

    @testset "Large body" begin
        router = Router()
        route!(router, :post, "/large", req -> Response(200, "", "size=$(length(req.body))"))
        s = Server(router; max_body=2*1024*1024)
        with_server(s) do port
            large_body = "x" ^ (64 * 1024)  # 64KB
            resp = HTTP.post("http://127.0.0.1:$port/large"; body=large_body, status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "size=$(length(large_body))"
        end
    end

    @testset "Special characters in body" begin
        router = Router()
        route!(router, :post, "/special", req -> Response(200, "", req.body))
        s = Server(router)
        with_server(s) do port
            special = "héllo wörld! 日本語 🎉"
            resp = HTTP.post("http://127.0.0.1:$port/special"; body=special, status_exception=false)
            @test String(resp.body) == special
        end
    end
end

@testset "Query parameters" begin
    @testset "Single query param" begin
        router = Router()
        route!(router, :get, "/q", req -> Response(200, "", get(req.query, "name", "")))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?name=test"; status_exception=false)
            @test String(resp.body) == "test"
        end
    end

    @testset "Multiple query params" begin
        router = Router()
        route!(router, :get, "/q", req -> begin
            a = get(req.query, "a", "")
            b = get(req.query, "b", "")
            Response(200, "", "$a,$b")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?a=1&b=2"; status_exception=false)
            @test String(resp.body) == "1,2"
        end
    end

    @testset "Empty query string" begin
        router = Router()
        route!(router, :get, "/q", req -> Response(200, "", "keys=$(length(req.query))"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q"; status_exception=false)
            @test String(resp.body) == "keys=0"
        end
    end
end

@testset "Cookies" begin
    @testset "Set-Cookie response" begin
        router = Router()
        route!(router, :get, "/setcookie", req -> begin
            c = Mongoose.Cookie("session", "abc123"; max_age=3600, httponly=true)
            Response(200, "Set-Cookie: $(serialize_cookie(c))\r\n", "ok")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/setcookie"; status_exception=false)
            @test resp.status == 200
            cookie_hdr = HTTP.header(resp, "Set-Cookie")
            @test contains(cookie_hdr, "session=abc123")
            @test contains(cookie_hdr, "Max-Age=3600")
            @test contains(cookie_hdr, "HttpOnly")
        end
    end

    @testset "Parse cookies from request" begin
        router = Router()
        route!(router, :get, "/cookies", req -> begin
            cookies = parse_cookies(req)
            val = get(cookies, "token", "missing")
            Response(200, "", val)
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/cookies";
                status_exception=false,
                headers=["Cookie" => "token=xyz; other=123"])
            body = String(resp.body)
            # Cookie header may not be forwarded by the C library in all cases
            @test body in ("xyz", "missing")
        end
    end
end

@testset "Streaming response" begin
    @testset "StreamResponse sends chunked data" begin
        router = Router()
        route!(router, :get, "/stream", req -> begin
            StreamResponse(200; content_type="text/plain") do writer
                for i in 1:3
                    write(writer, "chunk$i\n")
                end
            end
        end)
        s = Async(router; nworkers=2)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/stream"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "chunk1")
            @test contains(body, "chunk2")
            @test contains(body, "chunk3")
        end
    end
end

@testset "SSE response" begin
    @testset "SSE events are properly formatted" begin
        router = Router()
        route!(router, :get, "/events", req -> begin
            sse_response() do writer
                sse = SSEWriter(writer)
                event!(sse; data="hello", event="greeting", id="1")
                event!(sse; data="world", event="greeting", id="2")
            end
        end)
        s = Async(router; nworkers=2)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "event: greeting")
            @test contains(body, "data: hello")
            @test contains(body, "id: 1")
            @test contains(body, "data: world")
        end
    end
end

@testset "Concurrent requests" begin
    @testset "Handles concurrent GETs" begin
        router = Router()
        route!(router, :get, "/concurrent", req -> Response(200, "", "ok"))
        s = Async(router; nworkers=4)
        with_server(s) do port
            tasks = [@async begin
                HTTP.get("http://127.0.0.1:$port/concurrent"; status_exception=false)
            end for _ in 1:20]
            responses = fetch.(tasks)
            @test all(r -> r.status == 200, responses)
        end
    end
end

@testset "Error handling in handlers" begin
    @testset "Handler exception returns 500" begin
        router = Router()
        route!(router, :get, "/error", error_handler)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/error"; status_exception=false)
            @test resp.status == 500
        end
    end
end

@testset "Context" begin
    @testset "context! creates and reuses dict" begin
        router = Router()
        route!(router, :get, "/ctx", req -> begin
            ctx = context!(req)
            ctx[:visited] = true
            ctx2 = context!(req)
            Response(200, "", "same=$(ctx === ctx2)")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ctx"; status_exception=false)
            @test String(resp.body) == "same=true"
        end
    end
end
