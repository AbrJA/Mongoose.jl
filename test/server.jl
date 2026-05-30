@testset "Server construction" begin
    @testset "Default Server" begin
        s = Server()
        @test s isa Server
        @test s.core.running[] == false
    end

    @testset "Default Async" begin
        s = Async()
        @test s isa Async
        @test s.core.running[] == false
        @test s.nworkers == 4
        @test s.nqueue == 1024
    end

    @testset "Server with Router" begin
        router = Router()
        route!(router, :get, "/test", req -> Response(200, "", "ok"))
        s = Server(router)
        @test s isa Server
    end

    @testset "Async with custom workers" begin
        s = Async(Router(); nworkers=2, nqueue=512)
        @test s.nworkers == 2
        @test s.nqueue == 512
    end

    @testset "Server with Config" begin
        config = Config(poll_timeout=2, max_body=2048, nworkers=2, nqueue=256)
        s = Async(Router(), config)
        @test s.core.poll_timeout == 2
        @test s.core.max_body == 2048
        @test s.nworkers == 2
    end

    @testset "Invalid config" begin
        @test_throws ServerError Async(Router(); nworkers=0)
        @test_throws ServerError Async(Router(); nqueue=0)
        @test_throws ServerError Server(Router(); max_body=0)
        @test_throws ServerError Server(Router(); poll_timeout=-1)
    end
end

@testset "Server start/shutdown" begin
    @testset "Basic start and stop (Server)" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
        end
    end

    @testset "Basic start and stop (Async)" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Async(router; nworkers=2)
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
        end
    end

    @testset "Double shutdown is safe" begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", "ok"))
        s = Server(router)
        with_server(s) do port
            # First shutdown happens in with_server finally block
        end
        # Second shutdown should be a no-op
        shutdown!(s)
    end

    @testset "Server not running returns early on shutdown" begin
        s = Server()
        shutdown!(s)  # Should not throw
    end
end

@testset "Custom error responses" begin
    router = Router()
    route!(router, :get, "/", req -> Response(200, "", "ok"))
    s = Server(router)
    fail!(s, 404, Response(404, "", "Custom Not Found"))

    with_server(s) do port
        resp = HTTP.get("http://127.0.0.1:$port/nonexistent"; status_exception=false)
        @test resp.status == 404
        @test contains(String(resp.body), "Not Found")
    end
end

@testset "fail! validation" begin
    s = Server()
    @test_throws ServerError fail!(s, 99, Response(99, "", "bad"))
    @test_throws ServerError fail!(s, 600, Response(600, "", "bad"))
end

@testset "ServiceRegistry integration" begin
    registry = ServiceRegistry()
    register!(registry, :db, () -> "database_connection")

    router = Router()
    route!(router, :get, "/svc", req -> begin
        db = service(req, :db)
        Response(200, "", db)
    end)

    s = Server(router; services=registry)
    with_server(s) do port
        resp = HTTP.get("http://127.0.0.1:$port/svc"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "database_connection"
    end
end

@testset "Static router server" begin
    s = Server(TestRoutes)
    with_server(s) do port
        resp = HTTP.get("http://127.0.0.1:$port/hello"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "Hello Static"
    end
end
