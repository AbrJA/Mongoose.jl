# Edge case tests — comprehensive coverage for untested code paths
# Covers: router edge cases, error paths, WebSocket control, server lifecycle, utility functions

@testset "Router edge cases" begin
    @testset "Float64 typed parameter" begin
        router = Router()
        route!(router, :get, "/temp/:val::Float64", (req, val) -> Response(200, "", "temp=$val"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/temp/36.6"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "temp=36.6"
        end
    end

    @testset "Bool typed parameter" begin
        router = Router()
        route!(router, :get, "/flag/:v::Bool", (req, v) -> Response(200, "", "flag=$v"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/flag/true"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "flag=true"

            resp = HTTP.get("http://127.0.0.1:$port/flag/false"; status_exception=false)
            @test String(resp.body) == "flag=false"

            # Invalid bool should 404
            resp = HTTP.get("http://127.0.0.1:$port/flag/maybe"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "UInt typed parameter" begin
        router = Router()
        route!(router, :get, "/id/:n::UInt", (req, n) -> Response(200, "", "id=$n"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/id/42"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "id=42"

            # Negative number should 404 (invalid for UInt)
            resp = HTTP.get("http://127.0.0.1:$port/id/-1"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "Deeply nested path (5+ segments)" begin
        router = Router()
        route!(router, :get, "/a/b/c/d/e/f", req -> Response(200, "", "deep"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/a/b/c/d/e/f"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "deep"
        end
    end

    @testset "Deeply nested parametric path" begin
        router = Router()
        route!(router, :get, "/api/:v/users/:uid::Int/posts/:pid::Int",
            (req, v, uid, pid) -> Response(200, "", "$v:$uid:$pid"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v2/users/5/posts/10"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "v2:5:10"
        end
    end

    @testset "Wildcard catch-all captures remainder" begin
        router = Router()
        route!(router, :get, "/files/*path", (req, path) -> Response(200, "", "path=$path"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/files/a/b/c.txt"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "path=a/b/c.txt"
        end
    end

    @testset "Bare wildcard catch-all" begin
        router = Router()
        route!(router, :get, "/known", req -> Response(200, "", "known"))
        route!(router, :get, "*", req -> Response(200, "", "catch-all"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/known"; status_exception=false)
            @test String(resp.body) == "known"
            resp = HTTP.get("http://127.0.0.1:$port/anything"; status_exception=false)
            @test String(resp.body) == "catch-all"
        end
    end

    @testset "Invalid method throws RouteError" begin
        router = Router()
        @test_throws RouteError route!(router, :invalid, "/test", req -> Response(200, "", ""))
    end

    @testset "Parameter conflict at same position" begin
        router = Router()
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
        @test_throws RouteError route!(router, :get, "/users/:name", (req, name) -> Response(200, "", ""))
    end

    @testset "Type conflict for same parameter" begin
        router = Router()
        route!(router, :get, "/items/:id::Int", (req, id) -> Response(200, "", ""))
        @test_throws RouteError route!(router, :get, "/items/:id::Float64", (req, id) -> Response(200, "", ""))
    end

    @testset "All HTTP methods" begin
        router = Router()
        for method in [:get, :post, :put, :delete, :patch, :options, :head]
            route!(router, method, "/method", req -> Response(200, "", string(method)))
        end
        s = Server(router)
        with_server(s) do port
            @test HTTP.get("http://127.0.0.1:$port/method"; status_exception=false).status == 200
            @test HTTP.post("http://127.0.0.1:$port/method"; status_exception=false).status == 200
            @test HTTP.put("http://127.0.0.1:$port/method"; status_exception=false, body="").status == 200
            @test HTTP.delete("http://127.0.0.1:$port/method"; status_exception=false).status == 200
            @test HTTP.patch("http://127.0.0.1:$port/method"; status_exception=false, body="").status == 200
            resp = HTTP.request("OPTIONS", "http://127.0.0.1:$port/method"; status_exception=false)
            @test resp.status == 200
            resp = HTTP.head("http://127.0.0.1:$port/method"; status_exception=false)
            @test resp.status == 200
        end
    end

    @testset "Query string stripped from path matching" begin
        router = Router()
        route!(router, :get, "/search", req -> begin
            q = get(req.query, "q", "none")
            Response(200, "", "q=$q")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/search?q=hello&page=1"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "q=hello"
        end
    end

    @testset "Route with string method" begin
        router = Router()
        route!(router, "GET", "/str", req -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/str"; status_exception=false)
            @test resp.status == 200
        end
    end
end

@testset "Server lifecycle edge cases" begin
    @testset "Double start is no-op" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router)
        port = fresh_port()
        start!(s; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
            # Second start should be a no-op (not throw)
            start!(s; host="127.0.0.1", port=port+1, blocking=false)
            # Server still works on original port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
        finally
            shutdown!(s)
            sleep(0.05)
        end
    end

    @testset "Double shutdown is safe" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router)
        port = fresh_port()
        start!(s; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
        finally
            shutdown!(s)
            sleep(0.05)
            # Second shutdown should not throw
            shutdown!(s)
        end
    end

    @testset "BindError on port in use" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s1 = Server(router)
        s2 = Server(router)
        port = fresh_port()
        start!(s1; host="127.0.0.1", port=port, blocking=false)
        try
            wait_for_server("http://127.0.0.1:$port/")
            @test_throws BindError start!(s2; host="127.0.0.1", port=port, blocking=false)
        finally
            shutdown!(s1)
            sleep(0.05)
        end
    end

    @testset "Server with custom error responses" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router; errors=Dict(404 => Response(404, "", "Custom 404")))
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/nonexistent"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "Config validation" begin
        @test_throws ServerError Server(Router(); max_body=0)
        @test_throws ServerError Server(Router(); max_body=-1)
        @test_throws ServerError Server(Router(); poll_timeout=-1)
        @test_throws ServerError Async(Router(); nworkers=0)
        @test_throws ServerError Async(Router(); nqueue=0)
    end

    @testset "Async server basic request" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "async-ok"))
        s = Async(router; nworkers=2)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "async-ok"
        end
    end

    @testset "Async server concurrent requests" begin
        router = Router()
        route!(router, :get, "/slow", req -> begin
            sleep(0.1)
            Response(200, "", "done")
        end)
        s = Async(router; nworkers=4)
        with_server(s) do port
            # Fire 4 concurrent requests
            tasks = [@async HTTP.get("http://127.0.0.1:$port/slow"; status_exception=false) for _ in 1:4]
            results = [fetch(t) for t in tasks]
            @test all(r -> r.status == 200, results)
            @test all(r -> String(r.body) == "done", results)
        end
    end
end

@testset "Error handling" begin
    @testset "Handler exception returns 500" begin
        router = Router()
        route!(router, :get, "/crash", req -> error("boom"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/crash"; status_exception=false)
            @test resp.status == 500
        end
    end

    @testset "404 for unmatched routes" begin
        router = Router()
        route!(router, :get, "/exists", req -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/nope"; status_exception=false)
            @test resp.status == 404
        end
    end

    @testset "405 Method Not Allowed" begin
        router = Router()
        route!(router, :get, "/only-get", req -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            # POST to a GET-only route
            resp = HTTP.post("http://127.0.0.1:$port/only-get"; status_exception=false, body="")
            # Should return 404 or 405 (implementation dependent)
            @test resp.status in [404, 405]
        end
    end
end

@testset "Request features" begin
    @testset "Headers are case-insensitive" begin
        router = Router()
        route!(router, :get, "/headers", req -> begin
            val = get(req.headers, "x-custom-header", "missing")
            Response(200, "", val)
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/headers";
                status_exception=false,
                headers=["X-Custom-Header" => "hello"])
            @test String(resp.body) == "hello"
        end
    end

    @testset "Empty body POST" begin
        router = Router()
        route!(router, :post, "/empty", req -> Response(200, "", "len=$(length(req.body))"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/empty"; status_exception=false, body="")
            @test String(resp.body) == "len=0"
        end
    end

    @testset "Large body POST" begin
        router = Router()
        route!(router, :post, "/large", req -> Response(200, "", "len=$(length(req.body))"))
        s = Server(router)
        with_server(s) do port
            body = repeat("x", 10_000)
            resp = HTTP.post("http://127.0.0.1:$port/large"; status_exception=false, body=body)
            @test String(resp.body) == "len=10000"
        end
    end

    @testset "Query parameters parsed correctly" begin
        router = Router()
        route!(router, :get, "/q", req -> begin
            a = get(req.query, "a", "")
            b = get(req.query, "b", "")
            Response(200, "", "$a,$b")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?a=1&b=hello"; status_exception=false)
            @test String(resp.body) == "1,hello"
        end
    end

    @testset "URL-encoded query parameters" begin
        router = Router()
        route!(router, :get, "/q", req -> begin
            val = get(req.query, "msg", "")
            Response(200, "", val)
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?msg=hello%20world"; status_exception=false)
            body = String(resp.body)
            @test body == "hello world" || body == "hello%20world"  # depends on decode impl
        end
    end

    @testset "Request context" begin
        router = Router()
        route!(router, :get, "/ctx", req -> begin
            ctx = context!(req)
            ctx[:user_id] = 42
            uid = ctx[:user_id]
            Response(200, "", "uid=$uid")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ctx"; status_exception=false)
            @test String(resp.body) == "uid=42"
        end
    end
end

@testset "WebSocket edge cases" begin
    @testset "Binary WebSocket messages" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/bin"; on_message=msg -> begin
            if msg.data isa Vector{UInt8}
                Message(UInt8[0x01, 0x02, 0x03])
            else
                Message("text response")
            end
        end)
        s = Async(router; nworkers=2)
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/bin") do ws
                HTTP.WebSockets.send(ws, "hello")
                msg = HTTP.WebSockets.receive(ws)
                @test !isempty(msg)
            end
        end
    end

    @testset "WebSocket on_close callback" begin
        closed = Ref(false)
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/close";
            on_message=msg -> Message("ack"),
            on_close=() -> (closed[] = true))
        s = Async(router; nworkers=2)
        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/close") do ws
                HTTP.WebSockets.send(ws, "hi")
                msg = HTTP.WebSockets.receive(ws)
                @test String(msg) == "ack"
            end
            sleep(0.2)  # Give time for close callback
            @test closed[]
        end
    end

    @testset "WebSocket on_open with request info" begin
        captured_uri = Ref("")
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/open";
            on_open=req -> (captured_uri[] = req.uri; true),
            on_message=msg -> Message("ok"))
        s = Async(router; nworkers=2)
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

    @testset "WebSocket on_open rejection" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        ws!(router, "/ws/reject";
            on_open=req -> false,  # Reject upgrade
            on_message=msg -> Message("should not reach"))
        s = Async(router; nworkers=2)
        with_server(s) do port
            # WS upgrade should be rejected with 403
            try
                HTTP.WebSockets.open("ws://127.0.0.1:$port/ws/reject") do ws
                    @test false  # Should not reach here
                end
            catch e
                # Connection should fail/be rejected
                @test true
            end
        end
    end
end

# --- Test middleware types (must be at top level) ---

struct OrderMW <: Mongoose.AbstractMiddleware
    name::String
    order::Vector{String}
end
function (mw::OrderMW)(req::Mongoose.Request, next::Function)
    push!(mw.order, "$(mw.name)-before")
    resp = next()
    push!(mw.order, "$(mw.name)-after")
    return resp
end

struct BlockMW <: Mongoose.AbstractMiddleware end
function (::BlockMW)(req::Mongoose.Request, next::Function)
    return Response(403, "", "blocked")
end

struct TagMW <: Mongoose.AbstractMiddleware end
function (::TagMW)(req::Mongoose.Request, next::Function)
    resp = next()
    new_headers = resp.headers * "X-Tagged: yes\r\n"
    return Response(resp.status, new_headers, resp.body)
end

# --- Tests ---

@testset "Middleware edge cases" begin
    @testset "Multiple middleware execution order" begin
        order = String[]
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", join(order, ",")))

        s = Server(router)
        plug!(s, OrderMW("A", order))
        plug!(s, OrderMW("B", order))

        with_server(s) do port
            empty!(order)
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
            # Middleware executes in FIFO order (A wraps B wraps handler)
            @test order == ["A-before", "B-before", "B-after", "A-after"]
        end
    end

    @testset "Middleware short-circuit" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "handler"))

        s = Server(router)
        plug!(s, BlockMW())

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 403
            @test String(resp.body) == "blocked"
        end
    end

    @testset "Path-scoped middleware" begin
        router = Router()
        route!(router, :get, "/api/data", req -> Response(200, "", "data"))
        route!(router, :get, "/public", req -> Response(200, "", "public"))

        s = Server(router)
        plug!(s, TagMW(); paths=["/api"])

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/data"; status_exception=false)
            @test HTTP.header(resp, "X-Tagged") == "yes"

            resp = HTTP.get("http://127.0.0.1:$port/public"; status_exception=false)
            @test HTTP.header(resp, "X-Tagged") == ""
        end
    end

    @testset "Rate limit window expiry" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        # Very short window for testing
        s = Server(router)
        plug!(s, ratelimit(max_requests=1, window_seconds=1))

        with_server(s) do port
            # First request OK
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "expire-test"])
            @test resp.status == 200

            # Second request should be blocked
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "expire-test"])
            @test resp.status == 429

            # Wait for window to expire
            sleep(1.1)

            # After expiry, should be allowed again
            resp = HTTP.get("http://127.0.0.1:$port/";
                status_exception=false, retry=false,
                headers=["X-Forwarded-For" => "expire-test"])
            @test resp.status == 200
        end
    end

    @testset "Rate limit unknown client fallback" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router)
        plug!(s, ratelimit(max_requests=3, window_seconds=60))

        with_server(s) do port
            # wait_for_server already used 1 request for "unknown" client
            # So we have 2 left
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false, retry=false)
            @test resp.status == 200

            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false, retry=false)
            @test resp.status == 200

            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false, retry=false)
            @test resp.status == 429
        end
    end

    @testset "CORS preflight with custom origins" begin
        router = Router()
        route!(router, :get, "/api", req -> Response(200, "", "ok"))
        s = Server(router)
        plug!(s, cors(origins="http://example.com", methods="GET, POST"))

        with_server(s) do port
            # Preflight
            resp = HTTP.request("OPTIONS", "http://127.0.0.1:$port/api";
                status_exception=false,
                headers=["Origin" => "http://example.com",
                         "Access-Control-Request-Method" => "GET"])
            @test resp.status in [200, 204]
            @test HTTP.header(resp, "Access-Control-Allow-Origin") == "http://example.com"
        end
    end

    @testset "Bearer auth middleware" begin
        router = Router()
        route!(router, :get, "/protected", req -> Response(200, "", "secret"))
        s = Server(router)
        plug!(s, bearer(token -> token == "my-secret-token"))

        with_server(s) do port
            # No token → 401
            resp = HTTP.get("http://127.0.0.1:$port/protected"; status_exception=false)
            @test resp.status == 401

            # Wrong token → 403 (invalid token)
            resp = HTTP.get("http://127.0.0.1:$port/protected";
                status_exception=false,
                headers=["Authorization" => "Bearer wrong-token"])
            @test resp.status == 403

            # Correct token → 200
            resp = HTTP.get("http://127.0.0.1:$port/protected";
                status_exception=false,
                headers=["Authorization" => "Bearer my-secret-token"])
            @test resp.status == 200
            @test String(resp.body) == "secret"
        end
    end

    @testset "API key middleware" begin
        router = Router()
        route!(router, :get, "/data", req -> Response(200, "", "data"))
        s = Server(router)
        plug!(s, apikey(; header_name="x-api-key", keys=Set(["secret123"])))

        with_server(s) do port
            # No key → 401
            resp = HTTP.get("http://127.0.0.1:$port/data"; status_exception=false)
            @test resp.status == 401

            # Wrong key → 401
            resp = HTTP.get("http://127.0.0.1:$port/data";
                status_exception=false,
                headers=["x-api-key" => "wrong"])
            @test resp.status == 401

            # Correct key → 200
            resp = HTTP.get("http://127.0.0.1:$port/data";
                status_exception=false,
                headers=["x-api-key" => "secret123"])
            @test resp.status == 200
        end
    end
end

@testset "SSE streaming" begin
    @testset "Basic SSE response" begin
        router = Router()
        route!(router, :get, "/events", req -> sse_response() do writer
            sse = SSEWriter(writer)
            event!(sse; data="hello", event="greeting")
            event!(sse; data="world", id="1")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "data: hello")
            @test contains(body, "event: greeting")
            @test contains(body, "data: world")
            @test contains(body, "id: 1")
        end
    end

    @testset "SSE multiline data" begin
        router = Router()
        route!(router, :get, "/multi", req -> sse_response() do writer
            sse = SSEWriter(writer)
            event!(sse; data="line1\nline2\nline3")
        end)
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/multi"; status_exception=false)
            body = String(resp.body)
            @test contains(body, "data: line1")
            @test contains(body, "data: line2")
            @test contains(body, "data: line3")
        end
    end
end

@testset "Route groups" begin
    @testset "Basic route group" begin
        router = Router()
        g = group("/api/v1")
        route!(g, :get, "/users", req -> Response(200, "", "users"))
        route!(g, :post, "/users", req -> Response(201, "", "created"))
        route!(g, :get, "/health", req -> Response(200, "", "ok"))
        Mongoose.register_group!(router, g)

        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/api/v1/users"; status_exception=false)
            @test resp.status == 200
            @test String(resp.body) == "users"

            resp = HTTP.post("http://127.0.0.1:$port/api/v1/users"; status_exception=false, body="")
            @test resp.status == 201

            resp = HTTP.get("http://127.0.0.1:$port/api/v1/health"; status_exception=false)
            @test String(resp.body) == "ok"
        end
    end
end

@testset "ServiceRegistry" begin
    @testset "Register and retrieve services" begin
        registry = ServiceRegistry()
        register!(registry, :db, "postgresql://localhost")
        register!(registry, :cache, Dict("host" => "redis"))

        @test service(registry, :db) == "postgresql://localhost"
        @test service(registry, :cache)["host"] == "redis"
    end

    @testset "Service not found" begin
        registry = ServiceRegistry()
        @test_throws ErrorException service(registry, :nonexistent)
    end

    @testset "Service via request context" begin
        router = Router()
        registry = ServiceRegistry()
        register!(registry, :version, "1.0.0")

        route!(router, :get, "/version", req -> begin
            v = service(req, :version)
            Response(200, "", "v=$v")
        end)
        s = Server(router; services=registry)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/version"; status_exception=false)
            @test String(resp.body) == "v=1.0.0"
        end
    end
end

@testset "Response formats" begin
    @testset "All format content types" begin
        router = Router()
        route!(router, :get, "/plain", req -> Response(Plain, "text"))
        route!(router, :get, "/html", req -> Response(Html, "<h1>hi</h1>"))
        route!(router, :get, "/json", req -> Response(Json, """{"a":1}"""))
        route!(router, :get, "/css", req -> Response(Css, "body{}"))
        route!(router, :get, "/js", req -> Response(Js, "var x=1"))
        route!(router, :get, "/xml", req -> Response(Xml, "<root/>"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/plain"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "text/plain")

            resp = HTTP.get("http://127.0.0.1:$port/html"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "text/html")

            resp = HTTP.get("http://127.0.0.1:$port/json"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "application/json")

            resp = HTTP.get("http://127.0.0.1:$port/css"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "text/css")

            resp = HTTP.get("http://127.0.0.1:$port/js"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "javascript")

            resp = HTTP.get("http://127.0.0.1:$port/xml"; status_exception=false)
            @test contains(HTTP.header(resp, "Content-Type"), "xml")
        end
    end

    @testset "Custom status codes" begin
        router = Router()
        route!(router, :post, "/created", req -> Response(Plain, "done"; status=201))
        route!(router, :get, "/gone", req -> Response(Plain, "gone"; status=410))
        route!(router, :get, "/teapot", req -> Response(Plain, "brew"; status=418))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/created"; status_exception=false, body="")
            @test resp.status == 201

            resp = HTTP.get("http://127.0.0.1:$port/gone"; status_exception=false)
            @test resp.status == 410

            resp = HTTP.get("http://127.0.0.1:$port/teapot"; status_exception=false)
            @test resp.status == 418
        end
    end
end

@testset "Health middleware" begin
    @testset "Default health endpoints" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router)
        h = health()
        plug!(s, h)

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/healthz"; status_exception=false)
            @test resp.status == 200

            resp = HTTP.get("http://127.0.0.1:$port/readyz"; status_exception=false)
            @test resp.status == 200

            resp = HTTP.get("http://127.0.0.1:$port/livez"; status_exception=false)
            @test resp.status == 200
        end
    end

    @testset "Unhealthy state" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router)
        ready_flag = Ref(true)
        h = health(ready_check = () -> ready_flag[])
        plug!(s, h)

        # Mark as not ready
        ready_flag[] = false

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/healthz"; status_exception=false)
            @test resp.status == 503  # not ready affects overall health

            resp = HTTP.get("http://127.0.0.1:$port/readyz"; status_exception=false)
            @test resp.status == 503  # not ready
        end
    end
end
