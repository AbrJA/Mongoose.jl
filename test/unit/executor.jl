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

@testset "FakeExecutor (deterministic)" begin
    fe = FakeExecutor()
    @test !haspending(fe)

    # submit! only enqueues (never runs) and reports acceptance like Async.
    @test submit!(fe, () -> "first") == true
    @test haspending(fe)

    # run! executes inline in submission order and clears the queue.
    submit!(fe, () -> string("x", 2))
    @test run!(fe) == Any["first", "x2"]
    @test !haspending(fe)
    @test fe.results == Any["first", "x2"]

    # Order/backpressure determinism: jobs run FIFO, results recorded.
    fe2 = FakeExecutor()
    order = String[]
    for i in 1:3
        submit!(fe2, () -> (push!(order, "job$i"); i))
    end
    @test run!(fe2) == Any[1, 2, 3]
    @test order == ["job1", "job2", "job3"]

    # stop! clears queued work.
    fe3 = FakeExecutor()
    submit!(fe3, () -> 1)
    stop!(fe3)
    @test !haspending(fe3)
end

