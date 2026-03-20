using HTTP
using Mongoose
using Test

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
        server = Server()
        route!(server, :get, "/hello", greet)

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
        server = Server()
        route!(server, :get, "/hello", greet)
        route!(server, :get, "/echo/:name", echo)
        route!(server, :get, "/error", error_handler)

        start!(server, port=8092, blocking=false, workers=1)

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
        server = Server()
        route!(server, :get, "/users/:id::Int", (req, id) -> begin
            Response(200, Dict("Content-Type" => "text/plain"), "User $(id) type=$(typeof(id))")
        end)
        route!(server, :get, "/score/:val::Float64", (req, val) -> begin
            Response(200, Dict("Content-Type" => "text/plain"), "Score $(val) type=$(typeof(val))")
        end)
        route!(server, :get, "/greet/:name", (req, name) -> begin
            Response(200, Dict("Content-Type" => "text/plain"), "Hello $(name) type=$(typeof(name))")
        end)

        start!(server, port=8100, blocking=false, workers=1)
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

        server = Server()
        route!(server, :get, "/echo/:name", echo)
        start!(server, port=8093, blocking=false, workers=4)

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
        server1 = Server()
        server2 = Server()

        route!(server1, :get, "/s1", (req) -> Response(200, Dict{String,String}(), "Server 1"))
        route!(server2, :get, "/s2", (req) -> Response(200, Dict{String,String}(), "Server 2"))

        start!(server1, port=8094, blocking=false, workers=1)
        start!(server2, port=8095, blocking=false, workers=1)
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
        server = Server()
        use!(server, cors_middleware(origins="https://example.com"))
        route!(server, :get, "/api/data", (req) -> Response(200, Dict("Content-Type" => "application/json"), "{\"ok\":true}"))

        start!(server, port=8096, blocking=false, workers=1)
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
        server = Server()
        route!(server, :get, "/api/json", (req) -> json_response(Dict("message" => "hello", "count" => 42)))
        route!(server, :post, "/api/echo", (req) -> begin
            data = json_body(req)
            json_response(data)
        end)

        start!(server, port=8097, blocking=false, workers=1)
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
        server = Server()
        route!(server, :post, "/upload", (req) -> Response(200, "", "OK"))

        start!(server, port=8099, blocking=false, workers=1, max_body_size=100)
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
        server = Server(ws_router=WsRouter())

        ws!(server, "/chat", on_message=function (msg::WsMessage)
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

        start!(server, port=8097, blocking=false, workers=1)
        sleep(0.5)

        HTTP.WebSockets.open("ws://localhost:8097/chat") do ws
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

    # --- Test: Server (unified API, sync mode) ---
    @testset "Server Sync Mode" begin
        router = HttpRouter()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)

        server = Server(router)
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

    # --- Test: Server (unified API, async mode with workers) ---
    @testset "Server Async Mode" begin
        router = HttpRouter()
        route!(router, :get, "/hello", greet)
        route!(router, :get, "/echo/:name", echo)
        route!(router, :get, "/error", error_handler)

        server = Server(router)
        start!(server; port=8102, blocking=false, workers=4)

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

    # --- Test: Server restart with different worker counts ---
    @testset "Server Restart" begin
        router = HttpRouter()
        route!(router, :get, "/ping", (req) -> Response(200, "", "pong"))

        server = Server(router)

        # Start as sync
        start!(server; port=8103, blocking=false)
        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart as async with 2 workers
        start!(server; port=8103, blocking=false, workers=2)
        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end

        # Restart again as async with 4 workers
        start!(server; port=8103, blocking=false, workers=4)
        try
            response = HTTP.get("http://localhost:8103/ping")
            @test response.status == 200
            @test String(response.body) == "pong"
        finally
            shutdown!(server)
        end
    end

    # --- Test: Server with middleware ---
    @testset "Server Middleware" begin
        router = HttpRouter()
        route!(router, :get, "/api/data", (req) -> Response(200, "Content-Type: application/json\r\n", "{\"ok\":true}"))

        server = Server(router)
        use!(server, cors_middleware(origins="https://test.com"))
        start!(server; port=8104, blocking=false, workers=2)
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

    # --- Test: route! on Router directly ---
    @testset "route! on Router" begin
        router = HttpRouter()
        ret = route!(router, :get, "/test", (req) -> Response(200, "", "ok"))
        @test ret === router  # returns the router for chaining

        # Verify it registered correctly
        matched = Mongoose.match_route(router, :get, "/test")
        @test matched !== nothing
    end

end
