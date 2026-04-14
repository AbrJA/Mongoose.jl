using HTTP
using JSON
using Mongoose
using Test

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

@router Routes begin
    get("/hello", (req) -> Response(200, "", "Hello Static"))
    get("/user/:id::Int", (req, id) -> Response(200, "", "User $id"))
    ws("/chat", on_message=(msg) -> Message("Echo: $(msg.data)"))
end

@router WildcardApp begin
    get("/known",  req -> Response(200, "", "known"))
    get("/*path",  (req, path) -> Response(404, "", "not found: $path"))
end

@router TypedApp begin
    get("/item/:id::Int", (req, id) -> Response(200, "", "id=$id type=$(typeof(id))"))
end

@testset "Mongoose.jl" begin

    # --- Helper Functions ---
    function greet(request)
        body = "{\"message\":\"Hello World from Julia!\"}"
        Response(Json, body)
    end

    function echo(request, name)
        body = "Hello $name from Julia!"
        Response(body)
    end

    function error_handler(request, args...)
        error("Something went wrong!")
    end

    # Wait until the server is actually accepting connections.
    # A fixed sleep is unreliable on Windows where task scheduling is non-deterministic.
    function wait_for_server(url; timeout=10.0, interval=0.05)
        deadline = time() + timeout
        while time() < deadline
            try
                # status_exception=false: any HTTP response (even 404) means server is up
                HTTP.get(url; readtimeout=1, connect_timeout=1, status_exception=false)
                return  # server is reachable
            catch
                sleep(interval)
            end
        end
        error("Server at $url did not become ready within $(timeout)s")
    end

    # --- Test 1: Server ---
    @testset "Server" begin
        router = Router()
        route!(router, :get, "/hello", greet)

        server = Server(router)
        start!(server, port=8091, blocking=false)
        wait_for_server("http://localhost:8091/")

        try
            response = HTTP.get("http://localhost:8091/hello")
            @test response.status == 200
            @test String(response.body) == "{\"message\":\"Hello World from Julia!\"}"
        finally
            shutdown!(server)
        end
    end

    # --- Test 2: Async (Default) ---
    @testset "Async" begin
        router = Router()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)
        route!(router, :get, "/error", error_handler)

        server = Async(router; nworkers=1)
        start!(server, port=8092, blocking=false)
        wait_for_server("http://localhost:8092/")

        try
            # Basic GET
            response = HTTP.get("http://localhost:8092/hello")
            @test response.status == 200
            @test String(response.body) == "{\"message\":\"Hello World from Julia!\"}"

            # Dynamic Route
            response = HTTP.get("http://localhost:8092/echo/Alice")
            @test response.status == 200
            @test String(response.body) == "Hello Alice from Julia!"

            # 404 Not Found
            response = HTTP.get("http://localhost:8092/nonexistent"; status_exception=false)
            @test response.status == 404

            # 405 Method Not Allowed
            response = HTTP.post("http://localhost:8092/hello"; status_exception=false)
            @test response.status == 405

            # 500 Internal Server Error
            response = HTTP.get("http://localhost:8092/error"; status_exception=false)
            @test response.status == 500
        finally
            shutdown!(server)
        end
    end

    # --- Test 3: Typed Route Parameters ---
    @testset "Typed Route Parameters" begin
        router = Router()
        route!(router, :get, "/users/:id::Int", (req, id) -> begin
            Response("User $(id) type=$(typeof(id))")
        end)
        route!(router, :get, "/score/:val::Float64", (req, val) -> begin
            Response("Score $(val) type=$(typeof(val))")
        end)
        route!(router, :get, "/greet/:name", (req, name) -> begin
            Response("Hello $(name) type=$(typeof(name))")
        end)

        server = Async(router; nworkers=1)
        start!(server, port=8100, blocking=false)
        wait_for_server("http://localhost:8100/")

        try
            # Int parameter — should be parsed to Int
            response = HTTP.get("http://localhost:8100/users/42")
            @test response.status == 200
            @test String(response.body) == "User 42 type=Int64"

            # Float64 parameter
            response = HTTP.get("http://localhost:8100/score/3.14")
            @test response.status == 200
            @test String(response.body) == "Score 3.14 type=Float64"

            # String parameter (default, no type annotation)
            response = HTTP.get("http://localhost:8100/greet/World")
            @test response.status == 200
            @test String(response.body) == "Hello World type=String"

            # Invalid type — should return 404 (not match the route)
            response = HTTP.get("http://localhost:8100/users/abc"; status_exception=false)
            @test response.status == 404
        finally
            shutdown!(server)
        end
    end

    # --- Test 4: Multithreading (Async with workers) ---
    @testset "Multithreading" begin
        n_threads = Threads.nthreads()
        @info "Running multithreading tests with $n_threads threads"

        router = Router()
        route!(router, :get, "/echo/:name", echo)

        server = Async(router; nworkers=4)
        start!(server, port=8093, blocking=false)
        wait_for_server("http://localhost:8093/")

        try
            results = Channel{Tuple{Int,Int,String}}(10)

            @sync for i in 1:10
                @async begin
                    response = HTTP.get("http://localhost:8093/echo/User$i")
                    put!(results, (response.status, i, String(response.body)))
                end
            end

            for _ in 1:10
                status, i, body = take!(results)
                @test status == 200
                @test body == "Hello User$i from Julia!"
            end
        finally
            shutdown!(server)
        end
    end

    # --- Test 5: Multiple Instances ---
    @testset "Multiple Instances" begin
        router1 = Router()
        route!(router1, :get, "/s1", (req) -> Response(200, "", "Server 1"))
        router2 = Router()
        route!(router2, :get, "/s2", (req) -> Response(200, "", "Server 2"))

        server1 = Async(router1; nworkers=1)
        server2 = Async(router2; nworkers=1)

        start!(server1, port=8094, blocking=false)
        start!(server2, port=8095, blocking=false)
        sleep(1)

        try
            r1 = HTTP.get("http://localhost:8094/s1")
            @test String(r1.body) == "Server 1"

            r2 = HTTP.get("http://localhost:8095/s2")
            @test String(r2.body) == "Server 2"
        finally
            shutdown!(server1)
            shutdown!(server2)
        end
    end

    # --- Test 5: CORS Middleware ---
    @testset "CORS Middleware" begin
        router = Router()
        route!(router, :get, "/api/data", (req) -> Response(Json, "{\"ok\":true}"))

        server = Async(router; nworkers=1)
        plug!(server, cors(origins="https://example.com"))
        start!(server, port=8096, blocking=false)
        wait_for_server("http://localhost:8096/")

        try
            # Normal request should have CORS headers
            response = HTTP.get("http://localhost:8096/api/data")
            @test response.status == 200
            headers_dict = Dict(String(h.first) => String(h.second) for h in response.headers)
            @test haskey(headers_dict, "Access-Control-Allow-Origin")
            @test headers_dict["Access-Control-Allow-Origin"] == "https://example.com"

            # OPTIONS preflight
            response = HTTP.request("OPTIONS", "http://localhost:8096/api/data"; status_exception=false)
            @test response.status == 204
        finally
            shutdown!(server)
        end
    end

    # --- Test 6: JSON Integration ---
    @testset "JSON Integration" begin
        router = Router()
        route!(router, :get, "/api/json", (req) -> Response(Json, Dict("message" => "hello", "count" => 42)))
        route!(router, :post, "/api/echo", (req) -> begin
            data = JSON.parse(req.body)
            Response(Json, data)
        end)

        server = Async(router; nworkers=1)
        start!(server, port=8097, blocking=false)
        wait_for_server("http://localhost:8097/")

        try
            # JSON response
            response = HTTP.get("http://localhost:8097/api/json")
            @test response.status == 200
            headers_dict = Dict(String(h.first) => String(h.second) for h in response.headers)
            @test headers_dict["Content-Type"] == "application/json; charset=utf-8"
            body_str = String(response.body)
            @test occursin("hello", body_str)
            @test occursin("42", body_str)

            # JSON echo
            response = HTTP.post("http://localhost:8097/api/echo";
                headers=["Content-Type" => "application/json"],
                body="{\"key\":\"value\"}")
            @test response.status == 200
            @test occursin("value", String(response.body))
        finally
            shutdown!(server)
        end
    end

    # --- Test 7: Parse query ---
    @testset "Parse query" begin
        struct TestParams
            q::String
            page::Int
            active::Bool
        end

        params = Mongoose.query(TestParams, "q=hello+world&page=3&active=true")
        @test params.q == "hello world"
        @test params.page == 3
        @test params.active == true

        # Missing fields default to zero values
        params2 = Mongoose.query(TestParams, "q=test")
        @test params2.q == "test"
        @test params2.page == 0
        @test params2.active == false
    end

    # --- Test 8: Body Size Limit ---
    @testset "Body Size Limit" begin
        router = Router()
        route!(router, :post, "/upload", (req) -> Response(200, "", "OK"))

        server = Async(router; nworkers=1, max_body=100)
        start!(server, port=8099, blocking=false)
        wait_for_server("http://localhost:8099/")

        try
            # Small body — should succeed
            response = HTTP.post("http://localhost:8099/upload"; body="short")
            @test response.status == 200

            # Large body — should get 413
            large_body = repeat("x", 200)
            response = HTTP.post("http://localhost:8099/upload"; body=large_body, status_exception=false)
            @test response.status == 413
        finally
            shutdown!(server)
        end
    end

    # --- WebSocket Tests ---
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

                # Send binary
                HTTP.WebSockets.send(ws, UInt8[1, 2, 3])
                response = HTTP.WebSockets.receive(ws)
                @test response == UInt8[1, 2, 3]
            end
        finally
            shutdown!(server)
        end
    end

    # --- Test: Server with pre-built router ---
    @testset "Server with Router" begin
        router = Router()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)

        server = Server(router)
        start!(server; port=8101, blocking=false)
        wait_for_server("http://localhost:8101/")

        try
            response = HTTP.get("http://localhost:8101/hello")
            @test response.status == 200
            @test String(response.body) == "{\"message\":\"Hello World from Julia!\"}"

            response = HTTP.get("http://localhost:8101/echo/Bob")
            @test response.status == 200
            @test String(response.body) == "Hello Bob from Julia!"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Async with pre-built router ---
    @testset "Async with Router" begin
        router = Router()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)
        route!(router, :get, "/error", error_handler)

        server = Async(router; nworkers=4)
        start!(server; port=8102, blocking=false)
        wait_for_server("http://localhost:8102/")

        try
            response = HTTP.get("http://localhost:8102/hello")
            @test response.status == 200
            @test String(response.body) == "{\"message\":\"Hello World from Julia!\"}"

            response = HTTP.get("http://localhost:8102/echo/Alice")
            @test response.status == 200
            @test String(response.body) == "Hello Alice from Julia!"

            response = HTTP.get("http://localhost:8102/nonexistent"; status_exception=false)
            @test response.status == 404

            response = HTTP.get("http://localhost:8102/error"; status_exception=false)
            @test response.status == 500
        finally
            shutdown!(server)
        end
    end

    # --- Test: Restart with shared router ---
    @testset "Restart with Shared Router" begin
        router = Router()
        route!(router, :get, "/ping", (req) -> Response(200, "", "pong"))

        # Start as sync
        server = Server(router)
        start!(server; port=8103, blocking=false)
        wait_for_server("http://localhost:8103/")

        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart as async with 2 workers (same router)
        server = Async(router; nworkers=2)
        start!(server; port=8103, blocking=false)
        wait_for_server("http://localhost:8103/")

        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart again as async with 4 workers (same router)
        server = Async(router; nworkers=4)
        start!(server; port=8103, blocking=false)
        wait_for_server("http://localhost:8103/")

        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Async with middleware ---
    @testset "Async Middleware" begin
        router = Router()
        route!(router, :get, "/api/data", (req) -> Response(200, "Content-Type: application/json\r\n", "{\"ok\":true}"))

        server = Async(router; nworkers=2)
        plug!(server, cors(origins="https://test.com"))
        start!(server; port=8104, blocking=false)
        wait_for_server("http://localhost:8104/")

        try
            response = HTTP.get("http://localhost:8104/api/data")
            @test response.status == 200
            headers_dict = Dict(String(h.first) => String(h.second) for h in response.headers)
            @test headers_dict["Access-Control-Allow-Origin"] == "https://test.com"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Authentication Middleware ---
    @testset "Authentication Middleware" begin
        router = Router()
        route!(router, :get, "/secure", (req) -> Response(200, "", "Secret Data"))

        # 1. Bearer Auth
        server_bearer = Async(router; nworkers=1)
        plug!(server_bearer, bearer(token -> token == "magic-token"))
        start!(server_bearer; port=8105, blocking=false)
        wait_for_server("http://localhost:8105/")

        try
            # Valid token
            resp = HTTP.get("http://localhost:8105/secure"; headers=["Authorization" => "Bearer magic-token"])
            @test resp.status == 200
            @test String(resp.body) == "Secret Data"

            # Invalid token
            resp = HTTP.get("http://localhost:8105/secure"; headers=["Authorization" => "Bearer wrong"], status_exception=false)
            @test resp.status == 403

            # Missing header
            resp = HTTP.get("http://localhost:8105/secure"; status_exception=false)
            @test resp.status == 401
        finally
            shutdown!(server_bearer)
        end

        # 2. API Key Auth
        server_api = Async(router; nworkers=1)
        plug!(server_api, apikey(keys=Set(["key123"])))
        start!(server_api; port=8106, blocking=false)
        wait_for_server("http://localhost:8106/")

        try
            # Valid key
            resp = HTTP.get("http://localhost:8106/secure"; headers=["X-API-Key" => "key123"])
            @test resp.status == 200

            # Invalid key
            resp = HTTP.get("http://localhost:8106/secure"; headers=["X-API-Key" => "wrong"], status_exception=false)
            @test resp.status == 401
        finally
            shutdown!(server_api)
        end
    end

    # --- Test: Rate Limiting Middleware ---
    @testset "Rate Limiting Middleware" begin
        router = Router()
        route!(router, :get, "/limited", (req) -> Response(200, "", "OK"))

        server = Async(router; nworkers=1)
        # 3 requests per 10 seconds (1 consumed by wait_for_server probe + 2 actual test requests)
        plug!(server, ratelimit(max_requests=3, window_seconds=10))
        start!(server; port=8107, blocking=false)
        wait_for_server("http://localhost:8107/")

        try
            @test HTTP.get("http://localhost:8107/limited").status == 200
            @test HTTP.get("http://localhost:8107/limited").status == 200

            # Fourth request should be limited (3 already used: 1 probe + 2 test)
            resp = HTTP.get("http://localhost:8107/limited"; status_exception=false)
            @test resp.status == 429
            @test haskey(Dict(resp.headers), "Retry-After")
        finally
            shutdown!(server)
        end
    end

    # --- Test: Static Router (@router) ---
    @testset "Static Router (@router)" begin
        server = Server(Routes)
        start!(server; port=8108, blocking=false)
        wait_for_server("http://localhost:8108/")

        try
            # Basic GET
            resp = HTTP.get("http://localhost:8108/hello")
            @test resp.status == 200
            @test String(resp.body) == "Hello Static"

            # Typed Parameter
            resp = HTTP.get("http://localhost:8108/user/123")
            @test resp.status == 200
            @test String(resp.body) == "User 123"

            # WebSocket
            HTTP.WebSockets.open("ws://localhost:8108/chat") do ws
                HTTP.WebSockets.send(ws, "ping")
                @test String(HTTP.WebSockets.receive(ws)) == "Echo: ping"
            end
        finally
            shutdown!(server)
        end
    end

    # --- Test: Header Handling ---
    @testset "Header Handling" begin
        router = Router()
        route!(router, :get, "/headers", (req) -> begin
            user_agent = get(req.headers, "User-Agent", nothing)
            Response(200, "X-Custom: Received\r\n", "UA: $user_agent")
        end)

        server = Async(router; nworkers=1)
        start!(server; port=8109, blocking=false)
        wait_for_server("http://localhost:8109/")

        try
            resp = HTTP.get("http://localhost:8109/headers"; headers=["User-Agent" => "TestClient"])
            @test resp.status == 200
            @test String(resp.body) == "UA: TestClient"
            headers_dict = Dict(String(h.first) => String(h.second) for h in resp.headers)
            @test headers_dict["X-Custom"] == "Received"
        finally
            shutdown!(server)
        end
    end

    # --- Test: route! on Router directly ---
    @testset "route! on Router" begin
        router = Router()
        ret = route!(router, :get, "/test", (req) -> Response(200, "", "ok"))
        @test ret === router  # returns the router for chaining

        # Verify it registered correctly
        matched = Mongoose._matchroute(router, :get, "/test")
        @test matched !== nothing
    end

    # --- Test: Logger Middleware ---
    @testset "Logger Middleware" begin
        router = Router()
        route!(router, :get, "/logged", (req) -> Response(200, "", "OK"))

        log_buf = IOBuffer()
        server = Async(router; nworkers=1)
        plug!(server, logger(output=log_buf))
        start!(server; port=8110, blocking=false)
        wait_for_server("http://localhost:8110/")

        try
            resp = HTTP.get("http://localhost:8110/logged")
            @test resp.status == 200
            sleep(0.2)  # let worker flush log

            log_output = String(take!(log_buf))
            @test occursin("GET", log_output)
            @test occursin("/logged", log_output)
            @test occursin("200", log_output)
            @test occursin("ms)", log_output)
        finally
            shutdown!(server)
        end
    end

    # --- Test: Logger Middleware with Threshold ---
    @testset "Logger Threshold" begin
        router = Router()
        route!(router, :get, "/fast", (req) -> Response(200, "", "OK"))

        log_buf = IOBuffer()
        server = Async(router; nworkers=1)
        plug!(server, logger(threshold=5000, output=log_buf))
        start!(server; port=8111, blocking=false)
        wait_for_server("http://localhost:8111/")

        try
            resp = HTTP.get("http://localhost:8111/fast")
            @test resp.status == 200
            sleep(0.2)

            # Fast request should NOT be logged (threshold=5000ms)
            log_output = String(take!(log_buf))
            @test isempty(log_output)
        finally
            shutdown!(server)
        end
    end

    # --- Test: Query String Stripping in Dynamic Router ---
    @testset "Query String Stripping" begin
        router = Router()
        route!(router, :get, "/search", (req) -> Response(200, "", "found"))
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", "user $id"))

        server = Server(router)
        start!(server; port=8112, blocking=false)
        wait_for_server("http://localhost:8112/")

        try
            # Fixed route with query string
            resp = HTTP.get("http://localhost:8112/search?q=hello&page=1")
            @test resp.status == 200
            @test String(resp.body) == "found"

            # Dynamic route with query string
            resp = HTTP.get("http://localhost:8112/users/42?expand=true")
            @test resp.status == 200
            @test String(resp.body) == "user 42"
        finally
            shutdown!(server)
        end
    end

    # --- Test: HEAD Auto-Handling ---
    @testset "HEAD Auto from GET" begin
        router = Router()
        route!(router, :get, "/page", (req) -> Response(200, "X-Custom: yes\r\n", "body content"))

        server = Server(router)
        start!(server; port=8113, blocking=false)
        wait_for_server("http://localhost:8113/")

        try
            resp = HTTP.head("http://localhost:8113/page")
            @test resp.status == 200
            @test isempty(resp.body)
            @test HTTP.header(resp, "X-Custom") == "yes"
        finally
            shutdown!(server)
        end
    end

    # --- Test: String Method Route Registration ---
    @testset "String Method Route" begin
        server = Server(Router())
        route!(server, "GET", "/a", (req) -> Response(200, "", "from get"))
        route!(server, "POST", "/a", (req) -> Response(200, "", "from post"))
        start!(server; port=8115, blocking=false)
        wait_for_server("http://localhost:8115/")

        try
            resp = HTTP.get("http://localhost:8115/a")
            @test resp.status == 200
            @test String(resp.body) == "from get"

            resp = HTTP.post("http://localhost:8115/a")
            @test resp.status == 200
            @test String(resp.body) == "from post"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Request Context ---
    @testset "Request Context" begin
        router = Router()
        route!(router, :get, "/ctx", (req) -> begin
            # Context starts as nothing, context! allocates on first access
            ctx = context!(req)
            @assert ctx isa Dict{Symbol,Any}
            ctx[:user] = "alice"
            Response(200, "", "user=$(ctx[:user])")
        end)

        server = Server(router)
        start!(server; port=8116, blocking=false)
        wait_for_server("http://localhost:8116/")

        try
            resp = HTTP.get("http://localhost:8116/ctx")
            @test resp.status == 200
            @test String(resp.body) == "user=alice"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Static File Serving (C-level mount!) ---
    @testset "Static Files" begin
        # Create temp directory with test files
        mktempdir() do dir
            write(joinpath(dir, "index.html"), "<h1>Home</h1>")
            write(joinpath(dir, "style.css"), "body { color: red; }")
            mkdir(joinpath(dir, "sub"))
            write(joinpath(dir, "sub", "page.html"), "<p>Sub</p>")

            router = Router()
            route!(router, :get, "/api/hello", (req) -> Response(200, "", "hello"))

            server = Server(router)
            mount!(server, dir)
            start!(server; port=8117, blocking=false)
            wait_for_server("http://localhost:8117/")

            try
                # Serve index on root
                resp = HTTP.get("http://localhost:8117/")
                @test resp.status == 200
                @test String(resp.body) == "<h1>Home</h1>"

                # Serve CSS with correct MIME
                resp = HTTP.get("http://localhost:8117/style.css")
                @test resp.status == 200
                @test String(resp.body) == "body { color: red; }"

                # Serve from subdirectory
                resp = HTTP.get("http://localhost:8117/sub/page.html")
                @test resp.status == 200
                @test String(resp.body) == "<p>Sub</p>"

                # Non-existent file falls through to 404
                resp = HTTP.get("http://localhost:8117/missing.txt"; status_exception=false)
                @test resp.status == 404

                # Path traversal attempt
                resp = HTTP.get("http://localhost:8117/../../../etc/passwd"; status_exception=false)
                @test resp.status in (403, 404)

                # Normal route still works (routes take priority)
                resp = HTTP.get("http://localhost:8117/api/hello")
                @test resp.status == 200
                @test String(resp.body) == "hello"
            finally
                shutdown!(server)
            end
        end
    end

    # --- Test: Binary Response Body (mg_send path in _send!) ---
    @testset "Binary Response Body" begin
        # Vector{UInt8} bodies must be delivered byte-exact, including null bytes.
        # mg_http_reply uses printf/strlen internally and would truncate at 0x00.
        # _send! builds a raw HTTP response buffer and writes it with mg_send.
        #
        # Use a real 1×1 red PNG (67 bytes) as the payload — it contains multiple
        # null bytes in IHDR/IDAT chunks, making it a realistic stress-test.
        red1x1_png = UInt8[
            # PNG signature
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            # IHDR: 1×1, 8-bit RGB
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xde,
            # IDAT: zlib-compressed red pixel
            0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54,
            0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x01, 0xe2, 0x21, 0xbc, 0x33,
            # IEND
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
            0xae, 0x42, 0x60, 0x82,
        ]

        router = Router()
        route!(router, :get, "/image.png", req -> Response(200, "Content-Type: image/png\r\n", red1x1_png))

        server = Server(router)
        start!(server; port=8130, blocking=false)
        wait_for_server("http://localhost:8130/")

        try
            resp = HTTP.get("http://localhost:8130/image.png")
            @test resp.status == 200
            @test resp.body == red1x1_png
            @test length(resp.body) == length(red1x1_png)

            # Also test Async binary path
            arouter = Router()
            route!(arouter, :get, "/image.png", req -> Response(200, "Content-Type: image/png\r\n", red1x1_png))
            aserver = Async(arouter)
            start!(aserver; port=8131, blocking=false)
            wait_for_server("http://localhost:8131/")

            try
                resp2 = HTTP.get("http://localhost:8131/image.png")
                @test resp2.status == 200
                @test resp2.body == red1x1_png
            finally
                shutdown!(aserver)
            end
        finally
            shutdown!(server)
        end
    end

    # --- Test: Body with Percent Sign (mg_http_reply %s fix) ---
    @testset "Body Percent Sign" begin
        router = Router()
        route!(router, :get, "/pct", (req) -> Response(200, "", "100% done"))

        server = Server(router)
        start!(server; port=8118, blocking=false)
        wait_for_server("http://localhost:8118/")

        try
            resp = HTTP.get("http://localhost:8118/pct")
            @test resp.status == 200
            @test String(resp.body) == "100% done"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Server Same-Instance Restart ---
    @testset "Server Same-Instance Restart" begin
        router = Router()
        route!(router, :get, "/ping", (req) -> Response(200, "", "pong"))

        server = Server(router)
        start!(server; port=8119, blocking=false)
        wait_for_server("http://localhost:8119/")

        try
            resp = HTTP.get("http://localhost:8119/ping")
            @test resp.status == 200
            @test String(resp.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart the SAME instance
        start!(server; port=8119, blocking=false)
        wait_for_server("http://localhost:8119/")

        try
            resp = HTTP.get("http://localhost:8119/ping")
            @test resp.status == 200
            @test String(resp.body) == "pong"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Async Same-Instance Restart ---
    @testset "Async Same-Instance Restart" begin
        router = Router()
        route!(router, :get, "/ping", (req) -> Response(200, "", "pong"))

        server = Async(router; nworkers=2)
        start!(server; port=8120, blocking=false)
        wait_for_server("http://localhost:8120/")

        try
            resp = HTTP.get("http://localhost:8120/ping")
            @test resp.status == 200
            @test String(resp.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart the SAME instance
        start!(server; port=8120, blocking=false)
        wait_for_server("http://localhost:8120/")

        try
            resp = HTTP.get("http://localhost:8120/ping")
            @test resp.status == 200
            @test String(resp.body) == "pong"
        finally
            shutdown!(server)
        end
    end

    # --- Test: BindError on Occupied Port ---
    @testset "BindError on Occupied Port" begin
        router = Router()
        route!(router, :get, "/", (req) -> Response(200, "", "ok"))

        server1 = Server(router)
        start!(server1; port=8121, blocking=false)
        wait_for_server("http://localhost:8121/")

        try
            server2 = Server(router)
            @test_throws BindError start!(server2; port=8121, blocking=false)
            # server2 must be clean after the error
            @test !server2.core.running[]
        finally
            shutdown!(server1)
        end
    end

    # --- Test: Double start! is a no-op ---
    @testset "Double start! is no-op" begin
        router = Router()
        route!(router, :get, "/", (req) -> Response(200, "", "ok"))

        server = Server(router)
        start!(server; port=8122, blocking=false)
        wait_for_server("http://localhost:8122/")

        try
            start!(server; port=8123, blocking=false)  # different port — should be ignored
            # original port still works, 8123 never opened
            resp = HTTP.get("http://localhost:8122/")
            @test resp.status == 200
            @test_throws Exception HTTP.get("http://localhost:8123/")
        finally
            shutdown!(server)
        end
    end

    # --- Test: Health Middleware ---
    @testset "Health Middleware" begin
        router = Router()
        route!(router, :get, "/api", (req) -> Response(200, "", "ok"))

        # Healthy server
        s1 = Server(router)
        plug!(s1, health(health_check=() -> true, ready_check=() -> true, live_check=() -> true))
        start!(s1; port=8124, blocking=false)
        wait_for_server("http://localhost:8124/")

        try
            resp = HTTP.get("http://localhost:8124/healthz")
            @test resp.status == 200
            @test occursin("healthy", String(resp.body))

            resp = HTTP.get("http://localhost:8124/readyz")
            @test resp.status == 200
            @test occursin("ready", String(resp.body))

            resp = HTTP.get("http://localhost:8124/livez")
            @test resp.status == 200
            @test occursin("alive", String(resp.body))

            # Normal route still works
            resp = HTTP.get("http://localhost:8124/api")
            @test resp.status == 200
        finally
            shutdown!(s1)
        end

        # Unhealthy server
        s2 = Server(router)
        plug!(s2, health(health_check=() -> false))
        start!(s2; port=8125, blocking=false)
        wait_for_server("http://localhost:8125/")

        try
            resp = HTTP.get("http://localhost:8125/healthz"; status_exception=false)
            @test resp.status == 503
            @test occursin("unhealthy", String(resp.body))
        finally
            shutdown!(s2)
        end
    end

    # --- Test: RouteError on Invalid Method ---
    @testset "RouteError on Invalid Method" begin
        router = Router()
        @test_throws RouteError route!(router, :connect, "/path", (req) -> Response(200, "", ""))
        @test_throws RouteError route!(router, :trace, "/path", (req) -> Response(200, "", ""))
    end

    # --- Test: RouteError on Dynamic Param Type Conflict ---
    @testset "RouteError on Param Type Conflict" begin
        router = Router()
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
        # Same name, different type — must throw
        @test_throws RouteError route!(router, :post, "/users/:id::String", (req, id) -> Response(200, "", ""))
    end

    # --- Test: URL Percent-Decode ---
    @testset "URL Percent-Decode" begin
        struct PctParams
            q::String
            msg::String
        end

        p = Mongoose.query(PctParams, "q=hello%20world&msg=100%25+done")
        @test p.q == "hello world"
        @test p.msg == "100% done"

        # Invalid hex escape is passed through literally
        p2 = Mongoose.query(PctParams, "q=%ZZtest&msg=ok")
        @test p2.q == "%ZZtest"
        @test p2.msg == "ok"
    end

    # --- Test: Global shutdown!() ---
    @testset "Global shutdown!()" begin
        r1 = Router()
        route!(r1, :get, "/", (req) -> Response(200, "", "s1"))
        r2 = Router()
        route!(r2, :get, "/", (req) -> Response(200, "", "s2"))

        s1 = Server(r1)
        s2 = Server(r2)
        start!(s1; port=8126, blocking=false)
        start!(s2; port=8127, blocking=false)
        wait_for_server("http://localhost:8126/")
        wait_for_server("http://localhost:8127/")

        @test HTTP.get("http://localhost:8126/").status == 200
        @test HTTP.get("http://localhost:8127/").status == 200

        Mongoose.shutdown!()

        @test !s1.core.running[]
        @test !s2.core.running[]
    end

    # --- Test: Bearer Token Case-Insensitive Scheme ---
    @testset "Bearer Token Case-Insensitive Scheme" begin
        router = Router()
        route!(router, :get, "/secure", (req) -> Response(200, "", "ok"))

        server = Server(router)
        plug!(server, bearer(token -> token == "secret"))
        start!(server; port=8128, blocking=false)
        wait_for_server("http://localhost:8128/")

        try
            # Lowercase scheme must be accepted (RFC 7235)
            resp = HTTP.get("http://localhost:8128/secure"; headers=["Authorization" => "bearer secret"])
            @test resp.status == 200

            # UPPERCASE scheme must be accepted
            resp = HTTP.get("http://localhost:8128/secure"; headers=["Authorization" => "BEARER secret"])
            @test resp.status == 200

            # Wrong token still rejected regardless of scheme casing
            resp = HTTP.get("http://localhost:8128/secure"; headers=["Authorization" => "bearer wrong"], status_exception=false)
            @test resp.status == 403
        finally
            shutdown!(server)
        end
    end

    # --- Test: Rate Limit with X-Forwarded-For Multi-IP ---
    @testset "Rate Limit X-Forwarded-For" begin
        router = Router()
        route!(router, :get, "/limited", (req) -> Response(200, "", "OK"))

        server = Async(router; nworkers=1)
        plug!(server, ratelimit(max_requests=2, window_seconds=60))
        start!(server; port=8129, blocking=false)
        wait_for_server("http://localhost:8129/")

        try
            # Same client IP via different proxy chains must share the same bucket
            headers1 = ["X-Forwarded-For" => "10.0.0.1"]
            headers2 = ["X-Forwarded-For" => "10.0.0.1, proxy1.example.com"]

            @test HTTP.get("http://localhost:8129/limited"; headers=headers1).status == 200
            @test HTTP.get("http://localhost:8129/limited"; headers=headers2).status == 200

            # Third request from same client is rate-limited
            resp = HTTP.get("http://localhost:8129/limited"; headers=headers1, status_exception=false)
            @test resp.status == 429
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Unit Tests — pure in-process, no live server
    # ==========================================================================

    @testset "Unit: _matchroute quality" begin
        r = Router()
        route!(r, :get,  "/",                  req       -> Response(200, "", "root"))
        route!(r, :get,  "/users/:id::Int",    (req, id) -> Response(200, "", "user"))
        route!(r, :post, "/items",             req       -> Response(200, "", "items"))
        route!(r, :get,  "/a/b/c",            req       -> Response(200, "", "deep-fixed"))
        route!(r, :get,  "/a/:x",             (req, x)  -> Response(200, "", "dynamic-a"))

        # Root route
        m = Mongoose._matchroute(r, :get, "/")
        @test m !== nothing
        @test m.params == []

        # Typed param parsed
        m = Mongoose._matchroute(r, :get, "/users/42")
        @test m !== nothing
        @test m.params == [42]
        @test m.params[1] isa Int

        # Query string stripped before match
        m = Mongoose._matchroute(r, :get, "/users/7?verbose=true")
        @test m !== nothing
        @test m.params == [7]

        # Invalid type → no route match
        @test Mongoose._matchroute(r, :get, "/users/notanumber") === nothing

        # Static child beats dynamic: /a/b/c must not be captured by /a/:x
        m_deep = Mongoose._matchroute(r, :get, "/a/b/c")
        @test m_deep !== nothing

        # Dynamic fallback for non-fixed child
        m_dyn = Mongoose._matchroute(r, :get, "/a/hello")
        @test m_dyn !== nothing

        # POST-only route is not matched by GET
        m_post_items = Mongoose._matchroute(r, :post, "/items")
        @test m_post_items !== nothing

        # Unknown route → nothing
        @test Mongoose._matchroute(r, :get, "/nonexistent/path") === nothing

        # Wildcard catch-all: "*" fixed route acts as final fallback
        route!(r, :get, "*", req -> Response(200, "", "catchall"))
        m_wild = Mongoose._matchroute(r, :get, "/totally/unknown/path")
        @test m_wild !== nothing
    end

    @testset "Unit: _matchroute multi-segment typed params" begin
        r = Router()
        route!(r, :get, "/users/:uid::Int/posts/:pid::Int",
               (req, uid, pid) -> Response(200, "", "u=$uid p=$pid"))

        m = Mongoose._matchroute(r, :get, "/users/3/posts/7")
        @test m !== nothing
        @test m.params == [3, 7]
        @test m.params[1] isa Int
        @test m.params[2] isa Int

        @test Mongoose._matchroute(r, :get, "/users/abc/posts/7")  === nothing
        @test Mongoose._matchroute(r, :get, "/users/3/posts/nope") === nothing
    end

    @testset "Unit: _parseroute wildcard must be last segment" begin
        # Wildcard anywhere but last → error
        @test_throws ErrorException Mongoose._parseroute("/files/*name/extra")
        @test_throws ErrorException Mongoose._parseroute("/*wild/a/b")
        @test_throws ErrorException Mongoose._parseroute("/a/*mid/b")

        # Wildcard as the final segment → valid, type is String
        segs = Mongoose._parseroute("/assets/*rest")
        @test length(segs) == 2
        @test segs[end].value == "rest"
        @test segs[end].type  == String

        # No wildcard → unaffected
        segs2 = Mongoose._parseroute("/a/b/:id")
        @test length(segs2) == 3
    end

    @testset "Unit: _sanitizeid" begin
        @test Mongoose._sanitizeid("abc-123")     == "abc-123"
        @test Mongoose._sanitizeid("")             == ""

        # CRLF injection → empty string
        @test Mongoose._sanitizeid("ok\r\nevil")  == ""
        @test Mongoose._sanitizeid("id\nevil")    == ""
        @test Mongoose._sanitizeid("a\x00b")      == ""

        # Too long (>128 bytes) → empty string
        @test Mongoose._sanitizeid(repeat("a", 129)) == ""

        # Exactly 128 chars → valid
        edge = repeat("x", 128)
        @test Mongoose._sanitizeid(edge) == edge
    end

    @testset "Unit: Response constructors" begin
        # 3-arg: status, header string, body string
        r1 = Response("hello")
        @test r1.status == 200
        @test r1.body   == "hello"
        @test occursin("text/plain", r1.headers)

        # 3-arg: binary body
        r2 = Response(Binary, UInt8[1, 2, 3])
        @test r2.body == UInt8[1, 2, 3]

        # 2-arg: status + string body (uses text/plain)
        r3 = Response("created"; status=201)
        @test r3.status == 201
        @test r3.body   == "created"
        @test occursin("text/plain", r3.headers)

        # Format-typed constructors (avoid Json which has a test-overloaded encode)
        r4 = Response(Xml, "<root/>")
        @test r4.status == 200
        @test occursin("application/xml", r4.headers)

        r5 = Response(Html, "<p>hi</p>"; status=201)
        @test r5.status == 201
        @test occursin("text/html", r5.headers)

        # SubString body must be converted to String
        s   = SubString("hello world", 1, 5)
        r6  = Response(200, "", s)
        @test r6.body isa String
        @test r6.body == "hello"
    end

    @testset "Unit: query struct deserialization with optional fields" begin
        struct _QOptFields
            name::String
            age::Union{Int,Nothing}
            flag::Bool
        end

        # All fields present
        p1 = Mongoose.query(_QOptFields, "name=Alice&age=30&flag=true")
        @test p1.name == "Alice"
        @test p1.age  == 30
        @test p1.flag == true

        # Optional (Union{Int,Nothing}) absent → nothing
        p2 = Mongoose.query(_QOptFields, "name=Bob&flag=yes")
        @test p2.name == "Bob"
        @test p2.age  === nothing
        @test p2.flag == true

        # Unknown query keys are silently ignored
        p3 = Mongoose.query(_QOptFields, "name=X&unknown=42&age=1")
        @test p3.name == "X"
        @test p3.age  == 1
    end

    @testset "Unit: _staticexists path traversal boundary" begin
        mktempdir() do base
            # Two adjacent directories to test the prefix-check boundary
            dir_pub  = joinpath(base, "public")
            dir_pub2 = joinpath(base, "public2")
            mkdir(dir_pub)
            mkdir(dir_pub2)
            write(joinpath(dir_pub,  "ok.txt"),     "ok")
            write(joinpath(dir_pub2, "secret.txt"), "secret")

            # Legitimate in-root file is found
            @test  Mongoose._staticexists(dir_pub, "/", "/ok.txt")

            # Traversal via ../ to adjacent directory is blocked
            @test !Mongoose._staticexists(dir_pub, "/", "/../public2/secret.txt")

            # Root "/" without index.html → false
            @test !Mongoose._staticexists(dir_pub, "/", "/")

            # Adding index.html makes root "/" resolvable
            write(joinpath(dir_pub, "index.html"), "<h1>home</h1>")
            @test  Mongoose._staticexists(dir_pub, "/", "/")
        end
    end

    @testset "Unit: structured logger JSON format" begin
        log_buf = IOBuffer()
        lg  = logger(structured=true, output=log_buf)
        req = Request(:get, "/api/v1", "", Pair{String,String}[], "", nothing)
        lg(req, Any[], () -> Response(200, "", "ok"))
        out = String(take!(log_buf))

        @test occursin("\"method\":", out)
        @test occursin("\"GET\"",     out)
        @test occursin("\"uri\":",    out)
        @test occursin("\"/api/v1\"", out)
        @test occursin("\"status\":", out)
        @test occursin("200",         out)
        @test occursin("\"duration\":", out)
        @test occursin("\"ts\":",     out)
    end

    # ==========================================================================
    # HTTP Methods Coverage
    # ==========================================================================

    @testset "HTTP Methods: PUT PATCH DELETE OPTIONS" begin
        router = Router()
        route!(router, :put,     "/item", req -> Response(200, "", "put"))
        route!(router, :patch,   "/item", req -> Response(200, "", "patch"))
        route!(router, :delete,  "/item", req -> Response(204, "", ""))
        route!(router, :options, "/item", req -> Response(200, "Allow: GET, OPTIONS\r\n", ""))

        server = Async(router; nworkers=1)
        start!(server; port=8200, blocking=false)
        wait_for_server("http://localhost:8200/")

        try
            resp = HTTP.put("http://localhost:8200/item")
            @test resp.status == 200
            @test String(resp.body) == "put"

            resp = HTTP.patch("http://localhost:8200/item")
            @test resp.status == 200
            @test String(resp.body) == "patch"

            resp = HTTP.delete("http://localhost:8200/item")
            @test resp.status == 204

            resp = HTTP.request("OPTIONS", "http://localhost:8200/item")
            @test resp.status == 200
            @test HTTP.header(resp, "Allow") == "GET, OPTIONS"
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Multi-parameter route
    # ==========================================================================

    @testset "Multi-parameter route /users/:uid::Int/posts/:pid::Int" begin
        router = Router()
        route!(router, :get, "/users/:uid::Int/posts/:pid::Int",
               (req, uid, pid) -> Response(200, "", "uid=$uid pid=$pid"))

        server = Async(router; nworkers=1)
        start!(server; port=8201, blocking=false)
        wait_for_server("http://localhost:8201/")

        try
            resp = HTTP.get("http://localhost:8201/users/5/posts/12")
            @test resp.status == 200
            @test String(resp.body) == "uid=5 pid=12"

            # Wrong type in first segment → 404
            resp = HTTP.get("http://localhost:8201/users/alice/posts/12"; status_exception=false)
            @test resp.status == 404

            # Wrong type in second segment → 404
            resp = HTTP.get("http://localhost:8201/users/5/posts/nope"; status_exception=false)
            @test resp.status == 404
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Wildcard catch-all route via "*" path
    # ==========================================================================

    @testset "Wildcard catch-all via * path" begin
        router = Router()
        route!(router, :get, "/known", req -> Response(200, "", "known"))
        route!(router, :get, "*",      req -> Response(Html, "<h1>Custom 404</h1>"; status=404))

        server = Server(router)
        start!(server; port=8202, blocking=false)
        wait_for_server("http://localhost:8202/")

        try
            resp = HTTP.get("http://localhost:8202/known")
            @test resp.status == 200

            resp = HTTP.get("http://localhost:8202/anything/else"; status_exception=false)
            @test resp.status == 404
            @test String(resp.body) == "<h1>Custom 404</h1>"
            hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
            @test occursin("text/html", hdrs["Content-Type"])
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # PathFilter via plug! with paths= keyword
    # ==========================================================================

    @testset "PathFilter via plug! paths keyword" begin
        router = Router()
        route!(router, :get, "/api/data",    req -> Response(200, "", "api"))
        route!(router, :get, "/public/page", req -> Response(200, "", "public"))

        server = Async(router; nworkers=1)
        # Bearer auth only applies to /api routes
        plug!(server, bearer(token -> token == "secret"); paths=["/api"])
        start!(server; port=8203, blocking=false)
        wait_for_server("http://localhost:8203/")

        try
            # /public/* must pass without auth
            resp = HTTP.get("http://localhost:8203/public/page")
            @test resp.status == 200
            @test String(resp.body) == "public"

            # /api/* missing header → 401
            resp = HTTP.get("http://localhost:8203/api/data"; status_exception=false)
            @test resp.status == 401

            # /api/* correct token → 200
            resp = HTTP.get("http://localhost:8203/api/data";
                            headers=["Authorization" => "Bearer secret"])
            @test resp.status == 200
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Prometheus Metrics Middleware
    # ==========================================================================

    @testset "Metrics Middleware" begin
        router = Router()
        route!(router, :get,  "/api/hello", req -> Response(200, "", "hello"))
        route!(router, :post, "/api/data",  req -> Response(201, "", "created"))

        server = Async(router; nworkers=2)
        plug!(server, metrics())
        start!(server; port=8204, blocking=false)
        wait_for_server("http://localhost:8204/")

        try
            HTTP.get("http://localhost:8204/api/hello")
            HTTP.get("http://localhost:8204/api/hello")
            HTTP.post("http://localhost:8204/api/data")

            resp = HTTP.get("http://localhost:8204/metrics")
            @test resp.status == 200
            hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
            @test occursin("text/plain", hdrs["Content-Type"])

            body = String(resp.body)
            @test occursin("http_requests_total",             body)
            @test occursin("http_request_duration_seconds",   body)
            @test occursin("# TYPE http_requests_total",      body)
            # At least 2 GET/200 and 1 POST/201 recorded
            @test occursin("method=\"GET\",status=\"200\"} 2", body)
            @test occursin("method=\"POST\",status=\"201\"} 1", body)
            @test occursin("http_request_duration_seconds_count", body)
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Structured Logger (JSON) via live server
    # ==========================================================================

    @testset "Structured Logger (JSON) via live server" begin
        router = Router()
        route!(router, :get, "/log_me", req -> Response(200, "", "ok"))

        log_buf = IOBuffer()
        server  = Async(router; nworkers=1)
        plug!(server, logger(structured=true, output=log_buf))
        start!(server; port=8205, blocking=false)
        wait_for_server("http://localhost:8205/")

        try
            HTTP.get("http://localhost:8205/log_me")
            sleep(0.2)  # give worker time to flush the log line

            out = String(take!(log_buf))
            @test occursin("{\"method\":",    out)
            @test occursin("\"GET\"",         out)
            @test occursin("/log_me",         out)
            @test occursin("\"status\":200",  out)
            @test occursin("\"duration\":", out)
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Custom fail! for 500 and 413
    # ==========================================================================

    @testset "Custom fail! for 500 and 413" begin
        router = Router()
        route!(router, :get,  "/boom",   req -> error("deliberate crash"))
        route!(router, :post, "/upload", req -> Response(200, "", "ok"))

        server = Async(router; nworkers=1, max_body=50)
        fail!(server, 500, Response(Json, """{"error":"internal","code":500}"""; status=500))
        fail!(server, 413, Response(Json, """{"error":"too large","code":413}"""; status=413))
        start!(server; port=8206, blocking=false)
        wait_for_server("http://localhost:8206/")

        try
            resp = HTTP.get("http://localhost:8206/boom"; status_exception=false)
            @test resp.status == 500
            body = String(resp.body)
            @test occursin("internal", body)
            @test occursin("500",      body)

            resp = HTTP.post("http://localhost:8206/upload";
                             body=repeat("x", 100), status_exception=false)
            @test resp.status == 413
            body413 = String(resp.body)
            @test occursin("too large", body413)
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Multiple middlewares stacked (CORS + bearer)
    # ==========================================================================

    @testset "Multiple middlewares stacked: CORS + bearer auth" begin
        router = Router()
        route!(router, :get, "/api/secure", req -> Response(200, "", "secure data"))

        server = Async(router; nworkers=1)
        plug!(server, cors(origins="https://app.example.com"))
        plug!(server, bearer(token -> token == "tok123"))
        start!(server; port=8207, blocking=false)
        start!(server; port=8207, blocking=false)
        wait_for_server("http://localhost:8207/")

        try
            # Wrong token → 403; CORS headers must still be present (CORS runs first)
            resp = HTTP.get("http://localhost:8207/api/secure";
                            headers=["Authorization" => "Bearer wrong"],
                            status_exception=false)
            @test resp.status == 403
            hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
            @test haskey(hdrs, "Access-Control-Allow-Origin")
            @test hdrs["Access-Control-Allow-Origin"] == "https://app.example.com"

            # Correct token → 200 + CORS headers
            resp = HTTP.get("http://localhost:8207/api/secure";
                            headers=["Authorization" => "Bearer tok123"])
            @test resp.status == 200
            hdrs2 = Dict(String(h.first) => String(h.second) for h in resp.headers)
            @test hdrs2["Access-Control-Allow-Origin"] == "https://app.example.com"
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # mount! with URI prefix
    # ==========================================================================

    @testset "mount! with URI prefix" begin
        mktempdir() do dir
            write(joinpath(dir, "logo.txt"), "LOGO_DATA")
            mkdir(joinpath(dir, "sub"))
            write(joinpath(dir, "sub", "page.txt"), "SUB_PAGE")

            router = Router()
            route!(router, :get, "/api/ping", req -> Response(200, "", "pong"))
            server = Server(router)
            mount!(server, dir; uri_prefix="/static")
            start!(server; port=8208, blocking=false)
            wait_for_server("http://localhost:8208/")

            try
                # File served under prefix
                resp = HTTP.get("http://localhost:8208/static/logo.txt")
                @test resp.status == 200
                @test String(resp.body) == "LOGO_DATA"

                # Subdirectory file served under prefix
                resp = HTTP.get("http://localhost:8208/static/sub/page.txt")
                @test resp.status == 200
                @test String(resp.body) == "SUB_PAGE"

                # Without prefix → should not serve the file
                resp = HTTP.get("http://localhost:8208/logo.txt"; status_exception=false)
                @test resp.status == 404

                # Normal route still works alongside static serving
                resp = HTTP.get("http://localhost:8208/api/ping")
                @test resp.status == 200
                @test String(resp.body) == "pong"
            finally
                shutdown!(server)
            end
        end
    end

    # ==========================================================================
    # mount! with two directories registered simultaneously
    # ==========================================================================

    @testset "mount! multiple static directories" begin
        mktempdir() do base
            dir_a = joinpath(base, "site")
            dir_b = joinpath(base, "assets")
            mkdir(dir_a)
            mkdir(dir_b)
            write(joinpath(dir_a, "index.html"), "<h1>Home</h1>")
            write(joinpath(dir_b, "app.js"),     "console.log(1)")

            router = Router()
            server = Server(router)
            mount!(server, dir_a)                       # prefix "/"
            mount!(server, dir_b; uri_prefix="/assets") # prefix "/assets"
            start!(server; port=8209, blocking=false)
            wait_for_server("http://localhost:8209/")

            try
                resp = HTTP.get("http://localhost:8209/")
                @test resp.status == 200
                @test String(resp.body) == "<h1>Home</h1>"

                resp = HTTP.get("http://localhost:8209/assets/app.js")
                @test resp.status == 200
                @test String(resp.body) == "console.log(1)"
            finally
                shutdown!(server)
            end
        end
    end

    # ==========================================================================
    # Config construction
    # ==========================================================================

    @testset "Config for Server and Async" begin
        router = Router()
        route!(router, :get, "/ping", req -> Response(200, "", "pong"))

        cfg_sync = Config(poll_timeout=1, max_body=1024)
        s_sync   = Server(router, cfg_sync)
        start!(s_sync; port=8210, blocking=false)
        wait_for_server("http://localhost:8210/")

        try
            resp = HTTP.get("http://localhost:8210/ping")
            @test resp.status == 200
            @test String(resp.body) == "pong"
        finally
            shutdown!(s_sync)
        end

        cfg_async = Config(nworkers=2, nqueue=64, poll_timeout=0,
                                 max_body=2048, drain_timeout=1000)
        s_async   = Async(router, cfg_async)
        start!(s_async; port=8211, blocking=false)
        wait_for_server("http://localhost:8211/")

        try
            resp = HTTP.get("http://localhost:8211/ping")
            @test resp.status == 200
            @test String(resp.body) == "pong"
        finally
            shutdown!(s_async)
        end
    end

    # ==========================================================================
    # Async request_timeout → 504
    # ==========================================================================

    @testset "Async request_timeout → 504" begin
        router = Router()
        route!(router, :get, "/ping", req -> Response(200, "", "pong"))   # warmup route
        route!(router, :get, "/fast", req -> Response(200, "", "fast"))
        route!(router, :get, "/slow", req -> (sleep(5); Response(200, "", "never")))

        server = Async(router; nworkers=1, request_timeout=200)
        start!(server; port=8212, blocking=false)
        wait_for_server("http://localhost:8212/")

        # Warm up the JIT via a request that has no timing assertions.
        # Without this the first real request compiles the full dispatch chain
        # (>200 ms) and spuriously hits the timeout.
        HTTP.get("http://localhost:8212/ping")
        sleep(0.1)

        try
            resp = HTTP.get("http://localhost:8212/fast")
            @test resp.status == 200
            @test String(resp.body) == "fast"

            resp = HTTP.get("http://localhost:8212/slow";
                            readtimeout=10, status_exception=false)
            @test resp.status == 504
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # WebSocket on_open and on_close lifecycle callbacks
    # ==========================================================================

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
            sleep(0.2)  # give event loop time to fire MG_EV_CLOSE
            @test close_fired[]
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # WebSocket concurrent connections
    # ==========================================================================

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

    # ==========================================================================
    # API key with custom header name
    # ==========================================================================

    @testset "API key with custom header_name" begin
        router = Router()
        route!(router, :get, "/data", req -> Response(200, "", "secret"))

        server = Server(router)
        plug!(server, apikey(header_name="X-Token", keys=Set(["valid-key"])))
        start!(server; port=8215, blocking=false)
        wait_for_server("http://localhost:8215/")

        try
            # Custom header with valid key → 200
            resp = HTTP.get("http://localhost:8215/data";
                            headers=["X-Token" => "valid-key"])
            @test resp.status == 200

            # Default X-API-Key header is not checked here → 401
            resp = HTTP.get("http://localhost:8215/data";
                            headers=["X-API-Key" => "valid-key"],
                            status_exception=false)
            @test resp.status == 401

            # Missing header → 401
            resp = HTTP.get("http://localhost:8215/data"; status_exception=false)
            @test resp.status == 401
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # CORS default wildcard origin "*"
    # ==========================================================================

    @testset "CORS default wildcard origin *" begin
        router = Router()
        route!(router, :get, "/open", req -> Response(200, "", "open"))

        server = Server(router)
        plug!(server, cors())  # default: origins="*"
        start!(server; port=8216, blocking=false)
        wait_for_server("http://localhost:8216/")

        try
            resp = HTTP.get("http://localhost:8216/open")
            @test resp.status == 200
            hdrs = Dict(String(h.first) => String(h.second) for h in resp.headers)
            @test haskey(hdrs, "Access-Control-Allow-Origin")
            @test hdrs["Access-Control-Allow-Origin"] == "*"
            @test haskey(hdrs, "Access-Control-Allow-Methods")
            @test haskey(hdrs, "Access-Control-Allow-Headers")
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # route! on server returns server (for method chaining)
    # ==========================================================================

    @testset "route! on server returns server for chaining" begin
        server = Server(Router())
        ret1 = route!(server, :get,  "/a", req -> Response(200, "", "a"))
        @test ret1 === server
        ret2 = route!(server, :post, "/b", req -> Response(200, "", "b"))
        @test ret2 === server

        start!(server; port=8217, blocking=false)
        wait_for_server("http://localhost:8217/")

        try
            @test HTTP.get("http://localhost:8217/a").status == 200
            @test HTTP.post("http://localhost:8217/b").status == 200
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # @router static router: 404, 405, and invalid typed param
    # ==========================================================================

    @testset "@router: unknown route returns 404" begin
        server = Server(Routes)
        start!(server; port=8218, blocking=false)
        wait_for_server("http://localhost:8218/")

        try
            resp = HTTP.get("http://localhost:8218/nonexistent"; status_exception=false)
            @test resp.status == 404

            # Static router falls through to 404 for any unmatched method/path combination
            resp = HTTP.post("http://localhost:8218/hello"; status_exception=false)
            @test resp.status == 404
        finally
            shutdown!(server)
        end
    end

    @testset "@router: typed param :id::Int → typed dispatch and 404 on mismatch" begin
        server = Server(TypedApp)
        start!(server; port=8219, blocking=false)
        wait_for_server("http://localhost:8219/")

        try
            # Correctly typed value → 200
            resp = HTTP.get("http://localhost:8219/item/42")
            @test resp.status == 200
            body42 = String(resp.body)
            @test occursin("id=42", body42)
            @test occursin("Int",   body42)

            # Non-integer value for typed param → 404 (not a valid route)
            resp = HTTP.get("http://localhost:8219/item/notanint"; status_exception=false)
            @test resp.status == 404
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Wildcard route in @router (module-level WildcardApp defined at top of file)
    # ==========================================================================

    @testset "@router with wildcard catch-all route" begin
        server = Server(WildcardApp)
        start!(server; port=8220, blocking=false)
        wait_for_server("http://localhost:8220/")

        try
            resp = HTTP.get("http://localhost:8220/known")
            @test resp.status == 200

            resp = HTTP.get("http://localhost:8220/missing/thing"; status_exception=false)
            @test resp.status == 404
            @test occursin("not found:", String(resp.body))
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Health middleware: readyz and livez unhealthy states
    # ==========================================================================

    @testset "Health middleware: partial failure states" begin
        router = Router()

        # ready=false → readyz returns 503
        s1 = Server(router)
        plug!(s1, health(health_check=() -> true, ready_check=() -> false, live_check=() -> true))
        start!(s1; port=8221, blocking=false)
        wait_for_server("http://localhost:8221/")

        try
            resp = HTTP.get("http://localhost:8221/healthz"; status_exception=false)
            @test resp.status == 503
            @test occursin("unhealthy", String(resp.body))

            resp = HTTP.get("http://localhost:8221/readyz"; status_exception=false)
            @test resp.status == 503
            @test occursin("not ready", String(resp.body))

            resp = HTTP.get("http://localhost:8221/livez")
            @test resp.status == 200
            @test occursin("alive", String(resp.body))
        finally
            shutdown!(s1)
        end

        # live=false → livez returns 503
        s2 = Server(router)
        plug!(s2, health(live_check=() -> false))
        start!(s2; port=8222, blocking=false)

        try
            resp = HTTP.get("http://localhost:8222/livez"; status_exception=false)
            @test resp.status == 503
            @test occursin("dead", String(resp.body))
        finally
            shutdown!(s2)
        end
    end

    # ==========================================================================
    # Request context in handler (context! allocates lazily)
    # ==========================================================================

    @testset "context! lazy allocation and isolation between requests" begin
        router = Router()
        route!(router, :get, "/ctx/:key", (req, key) -> begin
            ctx = context!(req)
            ctx[:val] = key
            Response(200, "", "$(ctx[:val])")
        end)

        server = Async(router; nworkers=2)
        start!(server; port=8223, blocking=false)
        wait_for_server("http://localhost:8223/")

        try
            results = Vector{String}(undef, 5)
            @sync for i in 1:5
                let i = i
                    @async begin
                        resp = HTTP.get("http://localhost:8223/ctx/item$i")
                        results[i] = String(resp.body)
                    end
                end
            end
            for i in 1:5
                @test results[i] == "item$i"
            end
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Unicode-safe body round-trip
    # ==========================================================================

    @testset "Unicode body round-trip" begin
        emoji_body = "Hello 🌍 from Mongoose.jl — café résumé"

        router = Router()
        route!(router, :get,  "/unicode", req -> Response(emoji_body))
        route!(router, :post, "/echo",    req -> Response(req.body))

        server = Server(router)
        start!(server; port=8224, blocking=false)
        wait_for_server("http://localhost:8224/")

        try
            resp = HTTP.get("http://localhost:8224/unicode")
            @test resp.status == 200
            @test String(resp.body) == emoji_body

            resp = HTTP.post("http://localhost:8224/echo"; body=emoji_body)
            @test resp.status == 200
            @test String(resp.body) == emoji_body
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # X-Request-Id echo and injection protection (unit + live)
    # The live test only sends safe IDs; CRLF injection is caught by
    # _sanitizeid which is tested as a pure unit test above.
    # ==========================================================================

    @testset "X-Request-Id echoed in response" begin
        router = Router()
        route!(router, :get, "/id", req -> Response(200, "", "ok"))

        server = Server(router)
        start!(server; port=8225, blocking=false)
        wait_for_server("http://localhost:8225/")

        try
            # Valid ID is echoed back in the response header
            resp = HTTP.get("http://localhost:8225/id";
                            headers=["X-Request-Id" => "req-abc-123"])
            @test resp.status == 200
            @test HTTP.header(resp, "X-Request-Id") == "req-abc-123"

            # Long-but-valid 64-char ID is also echoed
            long_id = repeat("a", 64)
            resp = HTTP.get("http://localhost:8225/id";
                            headers=["X-Request-Id" => long_id])
            @test resp.status == 200
            @test HTTP.header(resp, "X-Request-Id") == long_id
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # WebSocket graceful close (RFC 6455 close handshake)
    # ==========================================================================

    @testset "WebSocket graceful close" begin
        router = Router()
        ws!(router, "/wsclose",
            on_message = (msg) -> Message("reply: $(msg.data)"))

        server = Server(router)
        start!(server; port=8226, blocking=false)
        wait_for_server("http://localhost:8226/")

        try
            # The do-block sends a message, receives the reply, then HTTP.jl sends a
            # close frame. The server must respond with a close frame (MG_EV_WS_CTL
            # handler) so the handshake completes without IOError.
            HTTP.WebSockets.open("ws://localhost:8226/wsclose") do ws
                HTTP.WebSockets.send(ws, "test")
                reply = String(HTTP.WebSockets.receive(ws))
                @test reply == "reply: test"
            end
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # _statustext returns empty string for unknown codes
    # ==========================================================================

    @testset "Unit: _statustext unknown code" begin
        @test Mongoose._statustext(200) == "OK"
        @test Mongoose._statustext(418) == ""
        @test Mongoose._statustext(999) == ""
        @test Mongoose._statustext(206) == "Partial Content"
        @test Mongoose._statustext(422) == "Unprocessable Entity"
    end

    # ==========================================================================
    # WebSocket upgrade rejection — on_open returning false → 403
    # ==========================================================================

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
            # Rejected upgrade: should get 403
            resp = HTTP.get("http://localhost:8227/ws/reject";
                headers=["Upgrade" => "websocket", "Connection" => "Upgrade",
                         "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==",
                         "Sec-WebSocket-Version" => "13"],
                status_exception=false)
            @test resp.status == 403

            # Accepted upgrade: should work normally
            HTTP.WebSockets.open("ws://localhost:8227/ws/accept") do ws
                HTTP.WebSockets.send(ws, "hello")
                reply = String(HTTP.WebSockets.receive(ws))
                @test reply == "accepted"
            end
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # @router auto-HEAD: HEAD on GET route → 200 with empty body
    # ==========================================================================

    @testset "@router: HEAD request on GET route returns 200 empty body" begin
        server = Server(Routes)
        start!(server; port=8228, blocking=false)
        wait_for_server("http://localhost:8228/")

        try
            # GET should return body
            resp_get = HTTP.get("http://localhost:8228/hello")
            @test resp_get.status == 200
            @test String(resp_get.body) == "Hello Static"

            # HEAD should return 200 but no body
            resp_head = HTTP.head("http://localhost:8228/hello"; status_exception=false)
            @test resp_head.status == 200
            @test isempty(resp_head.body)
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Dynamic router auto-HEAD: HEAD on GET route → 200 with empty body
    # ==========================================================================

    @testset "Router: HEAD request on GET route returns 200 empty body" begin
        router = Router()
        route!(router, :get, "/headtest", req -> Response(Plain, "head-body"))

        server = Async(router; nworkers=1)
        start!(server; port=8229, blocking=false)
        wait_for_server("http://localhost:8229/")

        try
            resp_get = HTTP.get("http://localhost:8229/headtest")
            @test resp_get.status == 200
            @test String(resp_get.body) == "head-body"

            resp_head = HTTP.head("http://localhost:8229/headtest"; status_exception=false)
            @test resp_head.status == 200
            @test isempty(resp_head.body)
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Server + ratelimit middleware (validates SpinLock fix)
    # ==========================================================================

    @testset "Server + ratelimit middleware (SpinLock)" begin
        router = Router()
        route!(router, :get, "/", req -> Response(Plain, "ok"))

        server = Server(router)
        plug!(server, ratelimit(max_requests=3, window_seconds=60))
        start!(server; port=8230, blocking=false)
        wait_for_server("http://localhost:8230/")

        try
            # wait_for_server consumed 1 request
            resp1 = HTTP.get("http://localhost:8230/")
            @test resp1.status == 200
            resp2 = HTTP.get("http://localhost:8230/")
            @test resp2.status == 200
            # 4th request should be rate-limited
            resp3 = HTTP.get("http://localhost:8230/"; status_exception=false)
            @test resp3.status == 429
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Server + metrics middleware (validates SpinLock fix)
    # ==========================================================================

    @testset "Server + metrics middleware (SpinLock)" begin
        router = Router()
        route!(router, :get, "/ping", req -> Response(Plain, "pong"))

        server = Server(router)
        plug!(server, metrics())
        start!(server; port=8231, blocking=false)
        wait_for_server("http://localhost:8231/")

        try
            HTTP.get("http://localhost:8231/ping")
            HTTP.get("http://localhost:8231/ping")

            resp = HTTP.get("http://localhost:8231/metrics")
            body = String(resp.body)
            @test occursin("http_requests_total", body)
            @test occursin("method=\"GET\"", body)
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # 503 status text
    # ==========================================================================

    @testset "Unit: _statustext 503" begin
        @test Mongoose._statustext(503) == "Service Unavailable"
    end

    # ==========================================================================
    # Dynamic router: typed param 404 on bad parse
    # ==========================================================================

    @testset "Router: typed param bad value → 404" begin
        router = Router()
        route!(router, :get, "/item/:id::Int", (req, id) -> Response(Plain, "id=$id"))

        server = Async(router; nworkers=1)
        start!(server; port=8232, blocking=false)
        wait_for_server("http://localhost:8232/")

        try
            resp = HTTP.get("http://localhost:8232/item/42")
            @test resp.status == 200
            @test occursin("id=42", String(resp.body))

            resp = HTTP.get("http://localhost:8232/item/abc"; status_exception=false)
            @test resp.status == 404
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Config with ws_idle_timeout
    # ==========================================================================

    @testset "Config: ws_idle_timeout parameter" begin
        config = Config(ws_idle_timeout=30)
        router = Router()
        route!(router, :get, "/", req -> Response(Plain, "ok"))
        server = Async(router, config)
        start!(server; port=8233, blocking=false)
        wait_for_server("http://localhost:8233/")

        try
            resp = HTTP.get("http://localhost:8233/")
            @test resp.status == 200
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # WS idle timeout behavioral test
    # ==========================================================================

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
            client_task = @async begin
                try
                    HTTP.WebSockets.open("ws://localhost:8234/idle") do ws
                        # Don't send anything — block until server closes the idle socket.
                        try
                            HTTP.WebSockets.receive(ws)
                        catch
                            client_observed_close[] = true
                        end
                    end
                catch
                    # If the connection fails unexpectedly, assertions below will fail.
                end
            end

            # Wait up to 10s for idle sweep + close propagation.
            deadline = time() + 10.0
            while close_count[] == 0 && time() < deadline
                sleep(0.2)
            end
            @test close_count[] >= 1
            @test client_observed_close[] == true
            wait(client_task)
        finally
            shutdown!(server)
        end
    end

    # ==========================================================================
    # Config validation
    # ==========================================================================

    @testset "Config validation rejects invalid values" begin
        @test_throws Mongoose.ServerError Async(Router(), Config(nworkers=0))
        @test_throws Mongoose.ServerError Async(Router(), Config(nqueue=0))
        @test_throws Mongoose.ServerError Async(Router(), Config(max_body=0))
        @test_throws Mongoose.ServerError Async(Router(), Config(drain_timeout=-1))
        @test_throws Mongoose.ServerError Server(Router(), Config(nworkers=0))
    end
end
