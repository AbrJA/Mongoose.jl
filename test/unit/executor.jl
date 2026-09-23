@testset "Executor contract" begin
    # SyncExecutor runs jobs inline.
    s = SyncExecutor()
    @test submit!(s, () -> 42) == 42
    @test haspending(s) == false

    # Missing capabilities fail loudly.
    struct _NoExec <: Mongoose.AbstractExecutor end
    @test_throws MethodError submit!(_NoExec(), () -> 1)
    @test_throws MethodError stop!(_NoExec())
end

@testset "Mongoose.Kernel.FakeExecutor (deterministic)" begin
    fe = Mongoose.Kernel.FakeExecutor()
    @test !haspending(fe)

    # submit! only enqueues (never runs) and reports acceptance like Async.
    @test submit!(fe, () -> "first") == true
    @test haspending(fe)

    # run! executes inline in submission order and clears the queue.
    submit!(fe, () -> string("x", 2))
    @test Mongoose.Kernel.run!(fe) == Any["first", "x2"]
    @test !haspending(fe)
    @test fe.results == Any["first", "x2"]

    # Order/backpressure determinism: jobs run FIFO, results recorded.
    fe2 = Mongoose.Kernel.FakeExecutor()
    order = String[]
    for i in 1:3
        submit!(fe2, () -> (push!(order, "job$i"); i))
    end
    @test Mongoose.Kernel.run!(fe2) == Any[1, 2, 3]
    @test order == ["job1", "job2", "job3"]

    # stop! clears queued work.
    fe3 = Mongoose.Kernel.FakeExecutor()
    submit!(fe3, () -> 1)
    stop!(fe3)
    @test !haspending(fe3)
end


@testset "AsyncExecutor stop! is bounded and drains replies" begin
    # A worker stuck in a never-returning job must not hang stop! forever.
    exec = AsyncExecutor(1, 4)
    start!(exec, nothing)
    submit!(exec, () -> sleep(5.0))
    sleep(0.1)                          # let the worker pick up the job
    t0 = time()
    stop!(exec; timeout=0.2)
    @test time() - t0 < 3.0

    # A full reply queue (worker blocked in put!) must not deadlock the join.
    exec2 = AsyncExecutor(1, 1)
    start!(exec2, nothing)
    for i in 1:6
        submit!(exec2, () -> i)
    end
    ok = timedwait(10.0; pollint=0.05) do
        stop!(exec2; timeout=2.0)
        true
    end
    @test ok == :ok
end
