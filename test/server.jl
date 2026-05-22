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

@testset "Async" begin
    router = Router()
    route!(router, :get, "/hello", greet)
    route!(router, :get, "/echo/:name", echo)
    route!(router, :get, "/error", error_handler)

    server = Async(router; nworkers=1)
    start!(server, port=8092, blocking=false)
    wait_for_server("http://localhost:8092/")

    try
        response = HTTP.get("http://localhost:8092/hello")
        @test response.status == 200
        @test String(response.body) == "{\"message\":\"Hello World from Julia!\"}"

        response = HTTP.get("http://localhost:8092/echo/Alice")
        @test response.status == 200
        @test String(response.body) == "Hello Alice from Julia!"

        response = HTTP.get("http://localhost:8092/nonexistent"; status_exception=false)
        @test response.status == 404

        response = HTTP.post("http://localhost:8092/hello"; status_exception=false)
        @test response.status == 405

        response = HTTP.get("http://localhost:8092/error"; status_exception=false)
        @test response.status == 500
    finally
        shutdown!(server)
    end
end

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

@testset "Restart with Shared Router" begin
    router = Router()
    route!(router, :get, "/ping", (req) -> Response(200, "", "pong"))

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

@testset "BindError on Occupied Port" begin
    router = Router()
    route!(router, :get, "/", (req) -> Response(200, "", "ok"))

    server1 = Server(router)
    start!(server1; port=8121, blocking=false)
    wait_for_server("http://localhost:8121/")

    try
        server2 = Server(router)
        @test_throws BindError start!(server2; port=8121, blocking=false)
        @test !server2.core.running[]
    finally
        shutdown!(server1)
    end
end

@testset "Double start! is no-op" begin
    router = Router()
    route!(router, :get, "/", (req) -> Response(200, "", "ok"))

    server = Server(router)
    start!(server; port=8122, blocking=false)
    wait_for_server("http://localhost:8122/")

    try
        start!(server; port=8123, blocking=false)  # different port — should be ignored
        resp = HTTP.get("http://localhost:8122/")
        @test resp.status == 200
        @test_throws Exception HTTP.get("http://localhost:8123/")
    finally
        shutdown!(server)
    end
end

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

@testset "Config validation rejects invalid values" begin
    @test_throws Mongoose.ServerError Async(Router(), Config(nworkers=0))
    @test_throws Mongoose.ServerError Async(Router(), Config(nqueue=0))
    @test_throws Mongoose.ServerError Async(Router(), Config(max_body=0))
    @test_throws Mongoose.ServerError Async(Router(), Config(drain_timeout=-1))
    @test_throws Mongoose.ServerError Server(Router(), Config(nworkers=0))

    @test_throws Mongoose.ServerError Async(Router(); nworkers=0)
    @test_throws Mongoose.ServerError Async(Router(); nqueue=0)
    @test_throws Mongoose.ServerError Async(Router(); request_timeout=-1)
    @test_throws Mongoose.ServerError Server(Router(); max_body=0)
    @test_throws Mongoose.ServerError Server(Router(); drain_timeout=-1)

    bad_errors = Dict(42 => Response(Plain, "bad"))
    @test_throws Mongoose.ServerError Async(Router(); errors=bad_errors)
    @test_throws Mongoose.ServerError Server(Router(); errors=bad_errors)
end
