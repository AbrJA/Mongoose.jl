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

