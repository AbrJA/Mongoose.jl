# Performance & Deployment

Mongoose.jl is designed so the production configuration is also the fast one:
`start!` freezes and compiles the route table, and middleware runs through a
tuple pipeline with no per-request closures. This page collects the measured
numbers, the tuning knobs that matter, and how to guard against regressions.

## Warm-path baselines

Measured with `bench/dispatch.jl` (Julia 1.13, warm, single thread; contexts
hoisted out of the measured loop). Treat them as relative baselines, not
guarantees — re-run the script on your hardware.

| Path | Allocations | Latency |
|---|---|---|
| `process` frozen fixed route | 192 B | ~225 ns |
| `process` frozen typed-param route | 528 B | ~400 ns |
| `process` frozen + route-scoped middleware | 192 B | ~350 ns |
| `process` frozen + `cors()` + `etag()` | 1024 B | ~1.3 µs |
| `process` generic fixed route | 256 B | ~700 ns |
| `process` generic typed-param route | 640 B | ~1.5 µs |
| `parse_method` | 0 B | ~4 ns |

A handler that returns `text("ok")`/`json(...)` costs one `Response` plus the
header block; header-adding middleware costs one `mergeheaders` (368 B) each.
Streams and binary bodies are hand-framed and always close the connection.

## The production recipe

```julia
app = App(;
    workers            = Threads.nthreads(),  # 0 = sync (inline handlers)
    queue_size         = 1024,                # 503 backpressure when full
    request_timeout_ms = 5_000,               # async only
    drain_timeout_ms   = 5_000,               # graceful shutdown budget
    max_body_bytes     = 1_048_576,
    header_timeout_ms  = 10_000,              # slowloris guard
    max_connections    = 10_000,
)

use!(app, security())
use!(app, etag())
use!(app, compress(min_size_bytes=1024))
use!(app, metrics())          # /metrics with counters, histogram, live gauges
use!(app, health())           # /healthz /readyz /livez

get!(app, "/users/:id::Int") do req, id
    json((id=id,))
end

start!(app; port=8080)        # binds, then freezes/compiles the route table
```

- **Freezing is automatic.** `start!` freezes the router after a successful
  bind, so production gets compiled dispatch without an extra call. A failed
  start does not freeze, so you can fix routes and retry. Register everything
  before `start!`; later registration throws.
- **Sync or async.** `workers=0` runs handlers inline (lowest overhead, one
  slow handler blocks the loop); `workers=N` runs a bounded pool with
  backpressure, per-request timeouts, and thread-safe reply delivery. Use
  async when handlers do I/O.
- **Scoped middleware is cheap.** `route!(...; middleware=(a, b))`,
  `group(...)`, and `use!(...; paths=["/api"])` all run through the tuple
  pipeline; route-scoped middleware adds no allocation over an unscoped route.
- **DI is typed.** `App(services=(db=pool,))` sets a typed `Request` field;
  read it with `withservices(req) do svcs … end` for type-stable access.
- **Limits protect the loop.** `header_timeout_ms` closes clients that stall
  before sending a request; `max_connections` refuses beyond the cap; bodies
  over `max_body_bytes` answer `413`. Configured body limits above the C
  receive ceiling (8 MiB on the current build) are rejected at construction.

## Observability

`metrics()` exposes `http_requests_total{method,status}`, the latency
histogram, and live gauges: `mongoose_connections`, `mongoose_ws_clients`,
`mongoose_active_streams`, `mongoose_executor_inflight`,
`mongoose_executor_queue_depth`. `logger()` emits access logs (including 500s
from throwing handlers) and `health()` serves Kubernetes probes. Shutdown on
SIGINT/SIGTERM drains in-flight requests and SSE streams, runs `onstop!` hooks,
and stops workers.

## Guarding against regressions

```sh
# Print the baseline table (or fail on regressions with BENCH_ASSERT=1)
julia --project=. bench/dispatch.jl
BENCH_ASSERT=1 julia --project=. bench/dispatch.jl

# The suite also enforces allocation ceilings and @inferred checks
julia --project=test test/unit/perf.jl
julia --project=test test/quality/quality.jl   # Aqua + JET baseline
```

CI runs the bench as an advisory step and the allocation guards as hard tests.
When you touch routing, the pipeline, or the transport, put before/after
numbers in the commit message and update the baseline table above plus the
`julia-performance` skill.

## AOT / `juliac --trim`

`freeze!` and the compiled route table are the foundation for AOT builds, but
`juliac --trim` support is **not complete yet**: the trim verifier still finds
dynamic dispatch in startup/registration (see `WORKLOG.md`, "AOT / trimming
readiness"). Use the standard Julia runtime until that lands.
