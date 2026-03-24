using HTTP
using JSON
using Mongoose
using Test

@router TestApp begin
    get("/hello", (req) -> Response(200, "", "Hello Static"))
    get("/user/:id::Int", (req, id) -> Response(200, "", "User $id"))
    ws("/chat", on_message=(msg) -> "Echo: $(msg.data)")
end

@testset "Mongoose.jl" begin

    # --- Helper Functions ---
    function greet(request)
        body = "{\"message\":\"Hello World from Julia!\"}"
        Response(200, Dict("Content-Type" => "application/json"), body)
    end

    function echo(request, name)
        body = "Hello $name from Julia!"
        Response(200, Dict("Content-Type" => "text/plain"), body)
    end

    function error_handler(request, args...)
        error("Something went wrong!")
    end

    # --- Test 1: SyncServer ---
    @testset "SyncServer" begin
        router = Router()
        route!(router, :get, "/hello", greet)

        server = SyncServer(router)
        start!(server, port=8091, blocking=false)

        try
            response = HTTP.get("http://localhost:8091/hello")
            @test response.status == 200
            @test String(response.body) == "{\"message\":\"Hello World from Julia!\"}"
        finally
            shutdown!(server)
        end
    end

    # --- Test 2: AsyncServer (Default) ---
    @testset "AsyncServer" begin
        router = Router()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)
        route!(router, :get, "/error", error_handler)

        server = AsyncServer(router; workers=1)
        start!(server, port=8092, blocking=false)

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
            Response(200, Dict("Content-Type" => "text/plain"), "User $(id) type=$(typeof(id))")
        end)
        route!(router, :get, "/score/:val::Float64", (req, val) -> begin
            Response(200, Dict("Content-Type" => "text/plain"), "Score $(val) type=$(typeof(val))")
        end)
        route!(router, :get, "/greet/:name", (req, name) -> begin
            Response(200, Dict("Content-Type" => "text/plain"), "Hello $(name) type=$(typeof(name))")
        end)

        server = AsyncServer(router; workers=1)
        start!(server, port=8100, blocking=false)
        sleep(0.5)

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

    # --- Test 4: Multithreading (AsyncServer with workers) ---
    @testset "Multithreading" begin
        n_threads = Threads.nthreads()
        @info "Running multithreading tests with $n_threads threads"

        router = Router()
        route!(router, :get, "/echo/:name", echo)

        server = AsyncServer(router; workers=4)
        start!(server, port=8093, blocking=false)

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

    # --- Test 4: Multiple Instances ---
    @testset "Multiple Instances" begin
        router1 = Router()
        route!(router1, :get, "/s1", (req) -> Response(200, Dict{String,String}(), "Server 1"))
        router2 = Router()
        route!(router2, :get, "/s2", (req) -> Response(200, Dict{String,String}(), "Server 2"))

        server1 = AsyncServer(router1; workers=1)
        server2 = AsyncServer(router2; workers=1)

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
        route!(router, :get, "/api/data", (req) -> Response(200, Dict("Content-Type" => "application/json"), "{\"ok\":true}"))

        server = AsyncServer(router; workers=1)
        use!(server, cors(origins="https://example.com"))
        start!(server, port=8096, blocking=false)
        sleep(0.5)

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
        route!(router, :get, "/api/json", (req) -> JsonResponse(Dict("message" => "hello", "count" => 42)))
        route!(router, :post, "/api/echo", (req) -> begin
            data = json_body(req)
            JsonResponse(data)
        end)

        server = AsyncServer(router; workers=1)
        start!(server, port=8097, blocking=false)
        sleep(0.5)

        try
            # JSON response
            response = HTTP.get("http://localhost:8097/api/json")
            @test response.status == 200
            headers_dict = Dict(String(h.first) => String(h.second) for h in response.headers)
            @test headers_dict["Content-Type"] == "application/json"
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

    # --- Test 7: parse_into ---
    @testset "parse_into" begin
        struct TestParams
            q::String
            page::Int
            active::Bool
        end

        params = parse_into(TestParams, "q=hello+world&page=3&active=true")
        @test params.q == "hello world"
        @test params.page == 3
        @test params.active == true

        # Missing fields default to zero values
        params2 = parse_into(TestParams, "q=test")
        @test params2.q == "test"
        @test params2.page == 0
        @test params2.active == false
    end

    # --- Test 8: Body Size Limit ---
    @testset "Body Size Limit" begin
        router = Router()
        route!(router, :post, "/upload", (req) -> Response(200, "", "OK"))

        server = AsyncServer(router; workers=1, max_body_size=100)
        start!(server, port=8099, blocking=false)
        sleep(0.5)

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
        ws!(router, "/chat", on_message=function (msg::WsMessage)
                if msg isa WsTextMessage
                    println("Server received text: ", msg.data)
                    return "Echo: " * msg.data
                else
                    println("Server received binary of length: ", length(msg.data))
                    return msg.data
                end
            end, on_open=function (req::Request)
                println("Server opened WS connection! Headers: ", req.headers)
            end, on_close=function ()
                println("Server closed WS connection!")
            end)

        server = AsyncServer(router, workers=1)
        start!(server, port=8098, blocking=false)
        sleep(0.5)

        HTTP.WebSockets.open("ws://localhost:8098/chat") do ws
            HTTP.WebSockets.send(ws, "Hello WebSockets!")
            response = HTTP.WebSockets.receive(ws)
            println("Client received: ", String(response))

            # Send binary
            HTTP.WebSockets.send(ws, UInt8[1, 2, 3])
            response = HTTP.WebSockets.receive(ws)
            println("Client received binary: ", response)
        end

        shutdown!(server)
    end

    # --- Test: SyncServer with pre-built router ---
    @testset "SyncServer with Router" begin
        router = Router()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)

        server = SyncServer(router)
        start!(server; port=8101, blocking=false)

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

    # --- Test: AsyncServer with pre-built router ---
    @testset "AsyncServer with Router" begin
        router = Router()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)
        route!(router, :get, "/error", error_handler)

        server = AsyncServer(router; workers=4)
        start!(server; port=8102, blocking=false)

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
        server = SyncServer(router)
        start!(server; port=8103, blocking=false)
        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart as async with 2 workers (same router)
        server = AsyncServer(router; workers=2)
        start!(server; port=8103, blocking=false)
        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart again as async with 4 workers (same router)
        server = AsyncServer(router; workers=4)
        start!(server; port=8103, blocking=false)
        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end
    end

    # --- Test: AsyncServer with middleware ---
    @testset "AsyncServer Middleware" begin
        router = Router()
        route!(router, :get, "/api/data", (req) -> Response(200, "Content-Type: application/json\r\n", "{\"ok\":true}"))

        server = AsyncServer(router; workers=2)
        use!(server, cors(origins="https://test.com"))
        start!(server; port=8104, blocking=false)
        sleep(0.5)

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
        server_bearer = AsyncServer(router; workers=1)
        use!(server_bearer, auth_bearer(token -> token == "magic-token"))
        start!(server_bearer; port=8105, blocking=false)
        sleep(0.5)

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
        server_api = AsyncServer(router; workers=1)
        use!(server_api, auth_api_key(keys=Set(["key123"])))
        start!(server_api; port=8106, blocking=false)
        sleep(0.5)

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

        server = AsyncServer(router; workers=1)
        # 2 requests per 10 seconds
        use!(server, rate_limit(max_requests=2, window_seconds=10))
        start!(server; port=8107, blocking=false)
        sleep(0.5)

        try
            @test HTTP.get("http://localhost:8107/limited").status == 200
            @test HTTP.get("http://localhost:8107/limited").status == 200

            # Third request should be limited
            resp = HTTP.get("http://localhost:8107/limited"; status_exception=false)
            @test resp.status == 429
            @test haskey(Dict(resp.headers), "Retry-After")
        finally
            shutdown!(server)
        end
    end

    # --- Test: Static Router (@router) ---
    @testset "Static Router (@router)" begin
        server = SyncServer(TestApp)
        start!(server; port=8108, blocking=false)
        sleep(0.5)

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
            user_agent = header(req, "User-Agent")
            Response(200, "X-Custom: Received\r\n", "UA: $user_agent")
        end)

        server = AsyncServer(router; workers=1)
        start!(server; port=8109, blocking=false)
        sleep(0.5)

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
        matched = Mongoose.match_route(router, :get, "/test")
        @test matched !== nothing
    end

    # --- Test: Logger Middleware ---
    @testset "Logger Middleware" begin
        router = Router()
        route!(router, :get, "/logged", (req) -> Response(200, "", "OK"))

        log_buf = IOBuffer()
        server = AsyncServer(router; workers=1)
        use!(server, logger(output=log_buf))
        start!(server; port=8110, blocking=false)
        sleep(0.5)

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
        server = AsyncServer(router; workers=1)
        use!(server, logger(threshold_ms=5000, output=log_buf))
        start!(server; port=8111, blocking=false)
        sleep(0.5)

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

        server = SyncServer(router)
        start!(server; port=8112, blocking=false)

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

        server = SyncServer(router)
        start!(server; port=8113, blocking=false)

        try
            resp = HTTP.head("http://localhost:8113/page")
            @test resp.status == 200
            @test isempty(resp.body)
            @test HTTP.header(resp, "X-Custom") == "yes"
        finally
            shutdown!(server)
        end
    end

    # --- Test: query(req, key) ---
    @testset "Query Param Lookup" begin
        router = Router()
        route!(router, :get, "/search", (req) -> begin
            q = query(req, "q")
            page = query(req, "page")
            missing_key = query(req, "nope")
            Response(200, "", "q=$(something(q, "")),page=$(something(page, "")),nope=$(something(missing_key, "nil"))")
        end)

        server = SyncServer(router)
        start!(server; port=8114, blocking=false)

        try
            resp = HTTP.get("http://localhost:8114/search?q=hello&page=2")
            @test resp.status == 200
            @test String(resp.body) == "q=hello,page=2,nope=nil"
        finally
            shutdown!(server)
        end
    end

    # --- Test: String Method Route Registration ---
    @testset "String Method Route" begin
        server = SyncServer(Router())
        route!(server, "GET", "/a", (req) -> Response(200, "", "from get"))
        route!(server, "POST", "/a", (req) -> Response(200, "", "from post"))
        start!(server; port=8115, blocking=false)

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
            # Context should be an empty dict by default
            @assert context(req) isa Dict{Symbol,Any}
            req.context[:user] = "alice"
            Response(200, "", "user=$(req.context[:user])")
        end)

        server = SyncServer(router)
        start!(server; port=8116, blocking=false)

        try
            resp = HTTP.get("http://localhost:8116/ctx")
            @test resp.status == 200
            @test String(resp.body) == "user=alice"
        finally
            shutdown!(server)
        end
    end

    # --- Test: parse_params Export ---
    @testset "parse_params Export" begin
        params = parse_params("name=alice&age=30&city=new+york")
        @test params["name"] == "alice"
        @test params["age"] == "30"
        @test params["city"] == "new york"
    end

    # --- Test: Static File Serving ---
    @testset "Static Files" begin
        # Create temp directory with test files
        mktempdir() do dir
            write(joinpath(dir, "index.html"), "<h1>Home</h1>")
            write(joinpath(dir, "style.css"), "body { color: red; }")
            mkdir(joinpath(dir, "sub"))
            write(joinpath(dir, "sub", "page.html"), "<p>Sub</p>")

            router = Router()
            route!(router, :get, "/api/hello", (req) -> Response(200, "", "hello"))

            server = SyncServer(router)
            use!(server, static_files(dir; prefix="/assets"))
            start!(server; port=8117, blocking=false)

            try
                # Serve index on prefix root
                resp = HTTP.get("http://localhost:8117/assets")
                @test resp.status == 200
                @test String(resp.body) == "<h1>Home</h1>"
                @test occursin("text/html", HTTP.header(resp, "Content-Type"))

                # Serve CSS with correct MIME
                resp = HTTP.get("http://localhost:8117/assets/style.css")
                @test resp.status == 200
                @test String(resp.body) == "body { color: red; }"
                @test occursin("text/css", HTTP.header(resp, "Content-Type"))

                # Serve from subdirectory
                resp = HTTP.get("http://localhost:8117/assets/sub/page.html")
                @test resp.status == 200
                @test String(resp.body) == "<p>Sub</p>"

                # Non-existent file falls through to route/404
                resp = HTTP.get("http://localhost:8117/assets/missing.txt"; status_exception=false)
                @test resp.status == 404

                # Path traversal attempt
                resp = HTTP.get("http://localhost:8117/assets/../../../etc/passwd"; status_exception=false)
                @test resp.status in (403, 404)

                # Normal route still works
                resp = HTTP.get("http://localhost:8117/api/hello")
                @test resp.status == 200
                @test String(resp.body) == "hello"
            finally
                shutdown!(server)
            end
        end
    end

    # --- Test: Body with Percent Sign (mg_http_reply %s fix) ---
    @testset "Body Percent Sign" begin
        router = Router()
        route!(router, :get, "/pct", (req) -> Response(200, "", "100% done"))

        server = SyncServer(router)
        start!(server; port=8118, blocking=false)

        try
            resp = HTTP.get("http://localhost:8118/pct")
            @test resp.status == 200
            @test String(resp.body) == "100% done"
        finally
            shutdown!(server)
        end
    end

end
