using HTTP
using Mongoose
using Test

@testset "Mongoose.jl" begin

    # --- Helper Functions ---
    function greet(request, params)
        body = "{\"message\":\"Hello World from Julia!\"}"
        Response(200, Dict("Content-Type" => "application/json"), body)
    end

    function echo(request, params)
        name = params["name"]
        body = "Hello $name from Julia!"
        Response(200, Dict("Content-Type" => "text/plain"), body)
    end

    function error_handler(request, params)
        error("Something went wrong!")
    end

    # --- Test 1: SyncServer ---
    @testset "SyncServer" begin
        server = SyncServer()
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
        server = AsyncServer()
        route!(server, :get, "/hello", greet)
        route!(server, :get, "/echo/:name", echo)
        route!(server, :get, "/error", error_handler)

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

    # --- Test 3: Multithreading (AsyncServer with workers) ---
    @testset "Multithreading" begin
        n_threads = Threads.nthreads()
        @info "Running multithreading tests with $n_threads threads"

        server = AsyncServer(nworkers=4)
        route!(server, :get, "/echo/:name", echo)
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
        server1 = AsyncServer()
        server2 = AsyncServer()

        route!(server1, :get, "/s1", (req, params) -> Response(200, Dict{String,String}(), "Server 1"))
        route!(server2, :get, "/s2", (req, params) -> Response(200, Dict{String,String}(), "Server 2"))

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
        server = AsyncServer()
        use!(server, cors_middleware(origins="https://example.com"))
        route!(server, :get, "/api/data", (req, params) -> Response(200, Dict("Content-Type" => "application/json"), "{\"ok\":true}"))

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
        server = AsyncServer()
        route!(server, :get, "/api/json", (req, params) -> json_response(Dict("message" => "hello", "count" => 42)))
        route!(server, :post, "/api/echo", (req, params) -> begin
            data = json_body(req)
            json_response(data)
        end)

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
        server = AsyncServer(max_body_size=100)
        route!(server, :post, "/upload", (req, params) -> Response(200, "", "OK"))

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
        server = AsyncServer(NoApp(), WsRouter(), nworkers=4)

        ws!(server, "/chat", on_message=function (msg::WsMessage)
                if msg isa WsTextMessage
                    println("Server received text: ", msg.data)
                    return "Echo: " * msg.data
                else
                    println("Server received binary of length: ", length(msg.data))
                    return msg.data
                end
            end, on_open=function (req::HttpRequest)
                println("Server opened WS connection! Headers: ", req.headers)
            end, on_close=function ()
                println("Server closed WS connection!")
            end)

        start!(server, port=8097, blocking=false)
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

end
