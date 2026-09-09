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
