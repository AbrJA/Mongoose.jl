@testset "App construction" begin
    @testset "Default App (sync)" begin
        app = App()
        @test app isa App
        @test app.runtime.running[] == false
        @test app.config.workers == 0
        @test app.executor isa SyncExecutor
    end

    @testset "Async App" begin
        app = App(workers=4)
        @test app isa App
        @test app.runtime.running[] == false
        @test app.config.workers == 4
        @test app.config.queue_size == 1024
        @test app.executor isa AsyncExecutor
        @test app.executor.workers == 4
        @test app.executor.queue_size == 1024
    end

    @testset "App with custom options" begin
        app = App(workers=2, queue_size=512, poll_timeout_ms=2, max_body_bytes=2048)
        @test app.config.workers == 2
        @test app.config.queue_size == 512
        @test app.config.poll_timeout_ms == 2
        @test app.config.max_body_bytes == 2048
    end

    @testset "App with invalid options" begin
        @test_throws ServerError App(max_body_bytes=0)
        @test_throws ServerError App(poll_timeout_ms=-1)
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

    @testset "start! returns the server" begin
        app = App()
        get!(app, "/") do req; text("ok") end
        @test start!(app; port=fresh_port(), blocking=false) === app
        @test start!(app; port=fresh_port(), blocking=false) === app  # already running
        shutdown!(app)
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

@testset "app-first registration order" begin
    started = Ref(false)
    stopped = Ref(false)
    ran = Ref(false)
    app = App()
    get!(app, "/") do req; text("ok") end
    @test onstart!(app, () -> (started[] = true)) === app
    @test onstop!(app, () -> (stopped[] = true)) === app
    @test background!(app, () -> (ran[] = true)) === app

    with_server(app) do port end
    @test started[] && stopped[] && ran[]
end

@testset "Per-request timeout (async)" begin
    app = App(workers=1, request_timeout_ms=150)
    get!(app, "/slow") do req
        sleep(1.0)
        text("late")
    end
    get!(app, "/fast") do req
        text("fast")
    end

    with_server(app) do port
        # retry=false: HTTP.jl would otherwise retry the 504 four times,
        # doubling up the tracked background tasks.
        resp = HTTP.get("http://127.0.0.1:$port/slow"; status_exception=false, retry=false)
        @test resp.status == 504

        # The timed-out handler task is tracked, not silently dropped; it
        # finishes on its own in the background.
        @test length(app.runtime.bg_tasks) == 1
        @test !istaskdone(app.runtime.bg_tasks[1])   # still running (sleep 1.0)
        @test timedwait(() -> istaskdone(app.runtime.bg_tasks[1]), 5.0;
                       pollint=0.01) == :ok

        resp2 = HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)
        @test resp2.status == 200
        @test String(resp2.body) == "fast"
    end
end

@testset "shutdown! drains background tasks (bounded by drain_timeout_ms)" begin
    @testset "short task is awaited and pruned" begin
        finished = Ref(false)
        app = App()
        get!(app, "/") do req; text("ok") end
        background!(app) do
            sleep(0.5)
            finished[] = true
        end

        with_server(app) do port
            @test HTTP.get("http://127.0.0.1:$port/"; status_exception=false).status == 200
        end

        # The drain grace period covered the task's remaining 0.5s.
        @test finished[]
        @test isempty(app.runtime.bg_tasks)
    end

    @testset "never-ending task is not joined" begin
        app = App(drain_timeout_ms=100)
        get!(app, "/") do req; text("ok") end
        background!(app) do
            sleep(60.0)
        end

        with_server(app) do port
            @test HTTP.get("http://127.0.0.1:$port/"; status_exception=false).status == 200
        end

        # Bounded wait gives up and keeps the still-running task.
        @test length(app.runtime.bg_tasks) == 1
        @test !istaskdone(app.runtime.bg_tasks[1])
    end
end

@testset "Queue-full 503 carries X-Request-Id" begin
    app = App(workers=1, queue_size=1, drain_timeout_ms=200)
    started = Channel{Nothing}(1)
    gate = Channel{Nothing}(1)
    blocked = Ref(false)
    get!(app, "/block") do req
        if !blocked[]
            blocked[] = true
            signal(started)
            take!(gate)
        end
        text("released")
    end

    with_server(app) do port
        base = "http://127.0.0.1:$port"
        blocker = Threads.@spawn HTTP.get("$base/block"; status_exception=false, retry=false)
        take!(started)                       # the single worker is parked in the handler

        # Worker busy + one queue slot: the burst must overflow into 503s.
        burst = [Threads.@spawn HTTP.get("$base/block"; status_exception=false, retry=false)
                 for _ in 1:4]
        overflowed = wait_until(timeout=5.0) do
            any(t -> istaskdone(t) && fetch(t).status == 503, burst)
        end
        put!(gate, nothing)                  # release the queued request
        @test overflowed

        responses = fetch.([blocker; burst])
        rejected = filter(r -> r.status == 503, responses)
        @test !isempty(rejected)
        @test all(r -> HTTP.hasheader(r, "X-Request-Id"), rejected)
    end
end

@testset "process-exit shutdown hook drains registered servers" begin
    # `atexit(_shutdown_registered!)` is the SIGTERM/exit path (Julia blocks
    # SIGTERM, so a custom handler cannot run). Exercise the hook directly.
    stopped = Ref(false)
    app = App()
    get!(app, "/") do req; text("ok") end
    onstop!(app) do; stopped[] = true end

    port = fresh_port()
    start!(app; host="127.0.0.1", port=port, blocking=false)
    wait_for_server("http://127.0.0.1:$port/")
    @test isrunning(app)

    Mongoose._shutdown_registered!()
    @test !isrunning(app)
    @test stopped[]
end

@testset "sync mode warns about ignored request_timeout_ms" begin
    app = App(request_timeout_ms=100)
    get!(app, "/") do req; text("ok") end
    @test_logs (:warn, r"request_timeout_ms is ignored in sync mode") match_mode=:any begin
        start!(app; port=fresh_port(), blocking=false)
    end
    shutdown!(app)
end

@testset "isrunning/url accessors" begin
    app = App()
    get!(app, "/") do req; text("ok") end
    @test !isrunning(app)
    @test url(app) === nothing
    with_server(app) do port
        @test isrunning(app)
        @test url(app) == "http://127.0.0.1:$port"
    end
    @test !isrunning(app)
    @test url(app) === nothing
end
