"""
    AbstractExecutor — controls where and how middleware + handlers run.

    The executor is the "where/how to run" half of the runtime. It owns the
    concurrency policy (inline vs worker pool), backpressure, and lifecycle of
    execution, so the transport and `App` never see `Channel`s or `Task`s.

    Handler jobs are closures `() → Union{Nothing, <:Tagged}` producing the
    reply to deliver (or `nothing` to drop). The executor only runs them and
    ships replies; it never interprets `Request`/`Response`/`Intent`.

    Reference implementations:
    - `SyncExecutor` — runs each job inline on the calling thread.
    - `AsyncExecutor` (server layer) — bounded worker pool + reply queue.

    ## Contract

    - `submit!(executor, job)` — schedule a job. `SyncExecutor` runs it
      inline and returns its value; pool executors return nothing.
    - `start!(executor, app)` / `stop!(executor)` — lifecycle.
    - `haspending(executor)` — is work still in flight? (drain support)

    Missing methods fail loudly via fallback methods below.
"""
abstract type AbstractExecutor end

# --- Reference implementation: inline execution ---

"""
    SyncExecutor — runs every job inline on the calling thread.

    This is the transport-agnostic equivalent of `workers=0` sync mode.
"""
struct SyncExecutor <: AbstractExecutor end

submit!(::SyncExecutor, job::Function) = job()::Any
start!(::SyncExecutor, app) = nothing
stop!(::SyncExecutor) = nothing

"""
    FakeExecutor — deterministic, thread-free executor for tests.

    Mirrors the `AsyncExecutor` contract (queued `submit!`, `haspending`,
    `start!`/`stop!`) but never spawns workers: jobs are queued and only run
    when the test calls `run!`, inline in submission order. This makes
    reply-order/backpressure tests deterministic — no threads, no sleeps.

    ```julia
    fe = FakeExecutor()
    submit!(fe, () -> "first")
    submit!(fe, () -> "second")
    @assert haspending(fe)
    @assert run!(fe) == ["first", "second"]
    @assert !haspending(fe)
    ```
"""
mutable struct FakeExecutor <: AbstractExecutor
    jobs::Vector{Function}
    results::Vector{Any}
end
FakeExecutor() = FakeExecutor(Function[], Any[])

start!(fe::FakeExecutor, app) = fe
stop!(fe::FakeExecutor) = (empty!(fe.jobs); empty!(fe.results); fe)

haspending(fe::FakeExecutor) = !isempty(fe.jobs)

# Queued jobs are never run implicitly: submit! only enqueues (accepted=true).
submit!(fe::FakeExecutor, job::Function) = (push!(fe.jobs, job); true)

"""
    run!(fe::FakeExecutor) → Vector{Any}

Run every queued job inline in submission order, clearing the queue and
recording each result.
"""
function run!(fe::FakeExecutor)
    ret = Any[]
    while !isempty(fe.jobs)
        job = popfirst!(fe.jobs)
        result = job()
        push!(fe.results, result)
        push!(ret, result)
    end
    return ret
end

# --- Contract-by-fallback methods ---

function submit!(executor::AbstractExecutor, job::Function)
    throw(MethodError(submit!, (executor, job)))
end

function start!(executor::AbstractExecutor, app)
    throw(MethodError(start!, (executor, app)))
end

function stop!(executor::AbstractExecutor)
    throw(MethodError(stop!, (executor,)))
end

haspending(::AbstractExecutor) = false
