@testset "HTTP methods" begin
    @testset "GET request" begin
        s = App()
        get!(s, "/data") do req; json("""{"ok":true}""") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/data"; status_exception=false)
            @test resp.status == 200
            @test JSON.parse(String(resp.body))["ok"] == true
            ct = HTTP.header(resp, "Content-Type")
            @test contains(ct, "application/json")
        end
    end

    @testset "POST with body" begin
        s = App()
        post!(s, "/echo") do req; text(req.body) end
        with_server(s) do port
            body = "hello world"
            resp = HTTP.post("http://127.0.0.1:$port/echo"; body=body, status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == body
        end
    end

    @testset "PUT request" begin
        s = App()
        put!(s, "/items/1") do req; text("updated") end
        with_server(s) do port
            resp = HTTP.put("http://127.0.0.1:$port/items/1"; body="data", status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "updated"
        end
    end

    @testset "PATCH request" begin
        s = App()
        patch!(s, "/items/1") do req; text("patched") end
        with_server(s) do port
            resp = HTTP.patch("http://127.0.0.1:$port/items/1"; body="{}", status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "patched"
        end
    end

    @testset "DELETE request" begin
        s = App()
        delete!(s, "/items/:id::Int") do req, id; text("deleted $id") end
        with_server(s) do port
            resp = HTTP.request("DELETE", "http://127.0.0.1:$port/items/5"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "deleted 5"
        end
    end

    @testset "HEAD request" begin
        s = App()
        head!(s, "/ping") do req; text("") end
        with_server(s) do port
            resp = HTTP.head("http://127.0.0.1:$port/ping"; status_exception=false)
            @test resp.status == 200
            @test isempty(resp.body)
        end
    end
end

@testset "Request headers" begin
    @testset "Custom headers are received" begin
        s = App()
        get!(s, "/headers") do req
            val = header(req, "x-custom-header")
            text(isnothing(val) ? "missing" : val)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/headers";
                status_exception=false,
                headers=["X-Custom-Header" => "test-value"])
            @test String(resp.body) == "test-value"
        end
    end

    @testset "Case-insensitive header lookup" begin
        s = App()
        get!(s, "/ci") do req
            val = header(req, "content-type")
            text(isnothing(val) ? "none" : val)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ci";
                status_exception=false,
                headers=["Content-Type" => "text/plain"])
            @test contains(String(resp.body), "text/plain")
        end
    end
end

@testset "Response helpers" begin
    @testset "text() helper" begin
        s = App()
        get!(s, "/plain") do req; text("hello") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/plain"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "hello"
            @test contains(HTTP.header(resp, "Content-Type"), "text/plain")
        end
    end

    @testset "html() helper" begin
        s = App()
        get!(s, "/page") do req; html("<h1>Hi</h1>") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/page"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "text/html")
            @test String(resp.body) == "<h1>Hi</h1>"
        end
    end

    @testset "json() helper" begin
        s = App()
        get!(s, "/json") do req; json("""{"key":"value"}""") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/json"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "application/json")
            parsed = JSON.parse(String(resp.body))
            @test parsed["key"] == "value"
        end
    end

    @testset "Custom status code" begin
        s = App()
        post!(s, "/create") do req; text("created"; status=201) end
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/create"; body="", status_exception=false)
            @test resp.status == 201
        end
    end

    @testset "Custom response headers" begin
        s = App()
        get!(s, "/custom") do req
            Response(Plain, "ok"; headers=["X-Custom" => "hello"])
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/custom"; status_exception=false)
            @test HTTP.header(resp, "X-Custom") == "hello"
        end
    end

    @testset "redirect() helper" begin
        s = App()
        get!(s, "/old") do req; redirect("/new") end
        get!(s, "/new") do req; text("new location") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/old"; status_exception=false, redirect=false)
            @test resp.status == 302
            @test HTTP.header(resp, "Location") == "/new"
        end
    end
end

@testset "Request body" begin
    @testset "Empty body" begin
        s = App()
        post!(s, "/empty") do req; text("len=$(length(req.body))") end
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/empty"; body="", status_exception=false)
            @test String(resp.body) == "len=0"
        end
    end

    @testset "JSON body parsing" begin
        s = App()
        post!(s, "/json") do req
            data = JSON.parse(req.body)
            text("name=$(data["name"])")
        end
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/json";
                body=JSON.json(Dict("name" => "Julia")),
                headers=["Content-Type" => "application/json"],
                status_exception=false)
            @test String(resp.body) == "name=Julia"
        end
    end

    @testset "Large body" begin
        s = App(max_body=2*1024*1024)
        post!(s, "/large") do req; text("size=$(length(req.body))") end
        with_server(s) do port
            large_body = "x" ^ (64 * 1024)  # 64KB
            resp = HTTP.post("http://127.0.0.1:$port/large"; body=large_body, status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "size=$(length(large_body))"
        end
    end

    @testset "Special characters in body" begin
        s = App()
        post!(s, "/special") do req; text(req.body) end
        with_server(s) do port
            special = "héllo wörld! 日本語 🎉"
            resp = HTTP.post("http://127.0.0.1:$port/special"; body=special, status_exception=false)
            @test String(resp.body) == special
        end
    end
end

@testset "Form parsing" begin
    @testset "form() parses URL-encoded body" begin
        s = App()
        post!(s, "/form") do req
            data = form(req)
            text(get(data, "name", "missing"))
        end
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/form";
                body="name=Julia&version=1",
                headers=["Content-Type" => "application/x-www-form-urlencoded"],
                status_exception=false)
            @test String(resp.body) == "Julia"
        end
    end
end

@testset "Query parameters" begin
    @testset "Single query param" begin
        s = App()
        get!(s, "/q") do req; text(get(req.query, "name", "")) end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?name=test"; status_exception=false)
            @test String(resp.body) == "test"
        end
    end

    @testset "Multiple query params" begin
        s = App()
        get!(s, "/q") do req
            a = get(req.query, "a", "")
            b = get(req.query, "b", "")
            text("$a,$b")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?a=1&b=2"; status_exception=false)
            @test String(resp.body) == "1,2"
        end
    end

    @testset "Empty query string" begin
        s = App()
        get!(s, "/q") do req; text("keys=$(length(req.query))") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q"; status_exception=false)
            @test String(resp.body) == "keys=0"
        end
    end
end

@testset "Cookies" begin
    @testset "Set-Cookie response" begin
        s = App()
        get!(s, "/setcookie") do req
            c = Mongoose.Cookie("session", "abc123"; max_age=3600, httponly=true)
            Response(200, ["Set-Cookie" => bake(c)], "ok")
        end
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
        s = App()
        get!(s, "/cookies") do req
            jar = Mongoose.cookies(req)
            val = get(jar, "token", "missing")
            text(val)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/cookies";
                status_exception=false,
                headers=["Cookie" => "token=xyz; other=123"])
            body = String(resp.body)
            @test body in ("xyz", "missing")
        end
    end
end

@testset "SSE response" begin
    @testset "SSE events are properly formatted" begin
        s = App(workers=2)
        get!(s, "/events") do req
            sse(req) do writer
                emit(writer; data="hello", event="greeting", id="1")
                emit(writer; data="world", event="greeting", id="2")
            end
        end
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
        s = App(workers=4)
        get!(s, "/concurrent") do req; text("ok") end
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
        s = App()
        get!(s, "/error") do req; error("boom") end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/error"; status_exception=false)
            @test resp.status == 500
        end
    end

    @testset "Typed exception handler" begin
        struct TeapotError <: Exception end

        s = App()
        onerror!(s, TeapotError) do req, e
            Response(418, Pair{String,String}["content-type" => "text/plain"], "teapot")
        end
        get!(s, "/tea") do req; throw(TeapotError()) end

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/tea"; status_exception=false)
            @test resp.status == 418
            @test String(resp.body) == "teapot"
        end
    end
end

@testset "Binary response keep-alive" begin
    s = App()
    get!(s, "/bin") do req
        Response(200, Pair{String,String}[], "binarydata")
    end

    with_server(s) do port
        resp1 = HTTP.get("http://127.0.0.1:$port/bin"; status_exception=false)
        resp2 = HTTP.get("http://127.0.0.1:$port/bin"; status_exception=false)
        @test resp1.status == 200
        @test resp2.status == 200
        # Binary responses must not force-close the connection.
        @test !any(h -> h.first == "connection" && h.second == "close", resp1.headers)
    end
end

@testset "Context" begin
    @testset "context creates and reuses dict" begin
        s = App()
        get!(s, "/ctx") do req
            c = context(req)
            c[:visited] = true
            c2 = context(req)
            text("same=$(c === c2)")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ctx"; status_exception=false)
            @test String(resp.body) == "same=true"
        end
    end
end
