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
        route!(server, "GET", "/hello", greet)

        # Start server in a background task since it blocks
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
        route!(server, "GET", "/hello", greet)
        route!(server, "GET", "/echo/:name", echo)
        route!(server, "GET", "/error", error_handler)

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
        route!(server, "GET", "/echo/:name", echo)
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

        route!(server1, "GET", "/s1", (req, params) -> Response(200, Dict{String,String}(), "Server 1"))
        route!(server2, "GET", "/s2", (req, params) -> Response(200, Dict{String,String}(), "Server 2"))

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
end
