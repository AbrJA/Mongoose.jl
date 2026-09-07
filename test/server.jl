@testset "App construction" begin
    @testset "Default App (sync)" begin
        app = App()
        @test app isa App
        @test app.running[] == false
        @test app.workers == 0
        @test app.executor isa SyncExecutor
    end

    @testset "Async App" begin
        app = App(workers=4)
        @test app isa App
        @test app.running[] == false
        @test app.workers == 4
        @test app.queuesize == 1024
        @test app.executor isa AsyncExecutor
        @test app.executor.workers == 4
        @test app.executor.queuesize == 1024
    end

    @testset "App with custom options" begin
        app = App(workers=2, queuesize=512, poll_timeout=2, max_body=2048)
        @test app.workers == 2
        @test app.queuesize == 512
        @test app.poll_timeout == 2
        @test app.max_body == 2048
    end

    @testset "App with invalid options" begin
        @test_throws ServerError App(max_body=0)
        @test_throws ServerError App(poll_timeout=-1)
    end
end

@testset "App start/shutdown" begin
    @testset "Basic start and stop (sync)" begin
        app = App()
        get!(app, "/") do req; text("ok") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
        end
    end

    @testset "Basic start and stop (async)" begin
        app = App(workers=2)
        get!(app, "/") do req; text("ok") end
        with_server(app) do port
            resp = HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            @test resp.status == 200
        end
    end

    @testset "Double shutdown is safe" begin
        app = App()
        get!(app, "/") do req; text("ok") end
        with_server(app) do port end
        shutdown!(app)  # second call should be no-op
    end

    @testset "Shutdown not-running is safe" begin
        app = App()
        shutdown!(app)
    end
end

@testset "Custom error responses" begin
    app = App()
    get!(app, "/") do req; text("ok") end
    onerror!(app, 404, Response(404, Pair{String,String}[], "Custom Not Found"))

    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/nonexistent"; status_exception=false)
        @test resp.status == 404
        @test contains(String(resp.body), "Not Found")
    end
end

@testset "onerror! validation" begin
    app = App()
    @test_throws ServerError onerror!(app, 99, Response(99, Pair{String,String}[], "bad"))
    @test_throws ServerError onerror!(app, 600, Response(600, Pair{String,String}[], "bad"))
end

@testset "service!/inject integration" begin
    app = App()
    service!(app, :db, () -> "database_connection")
    get!(app, "/svc") do req
        db = service(req, :db)
        text(db)
    end

    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/svc"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "database_connection"
    end
end

@testset "onstart! / onstop! hooks" begin
    started = Ref(false)
    stopped = Ref(false)
    app = App()
    get!(app, "/") do req; text("ok") end
    onstart!(app) do; started[] = true end
    onstop!(app) do; stopped[] = true end

    with_server(app) do port
        @test started[] == true
    end
    @test stopped[] == true
end

@testset "Per-request timeout (async)" begin
    app = App(workers=1, request_timeout=150)
    get!(app, "/slow") do req
        sleep(1.0)
        text("late")
    end
    get!(app, "/fast") do req
        text("fast")
    end

    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/slow"; status_exception=false)
        @test resp.status == 504

        resp2 = HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)
        @test resp2.status == 200
        @test String(resp2.body) == "fast"
    end
end
