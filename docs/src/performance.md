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
app = App(Threads.nthreads();                 # App() = sync (inline handlers)
    queue_size         = 1024,                # 503 backpressure when full
    request_timeout_ms = 5_000,               # async only
    drain_timeout_ms   = 5_000,               # graceful shutdown budget
    max_body_bytes     = 1_048_576,
    header_timeout_ms  = 10_000,              # slowloris guard
    body_timeout_ms    = 30_000,              # bound body uploads
    max_header_bytes   = 64 * 1024,           # header-size cap
    send_buffer_bytes  = 1_048_576,           # unsent bytes/conn (streams + WS)
    max_connections    = 10_000,
)

app = use(app, security())
app = use(app, etag())
app = use(app, compress(min_size_bytes=1024))
app = use(app, metrics()) # /metrics with counters, histogram, live gauges
app = use(app, health())  # /healthz /readyz /livez

get!(app, "/users/:id::Int") do req, id
    json((id=id,))
end

start!(app; port=8080)        # binds, then freezes/compiles the route table
```

- **Freezing is automatic.** `start!` freezes the router after a successful
  bind, so production gets compiled dispatch without an extra call. A failed
  start does not freeze, so you can fix routes and retry. Register everything
  before `start!`; later registration throws.
- **Sync or async.** `App()` runs handlers inline (lowest overhead, one slow
  handler blocks the loop); `App(N)` runs a bounded pool with backpressure,
  per-request timeouts, and thread-safe reply delivery. Use async when handlers
  do I/O. For a runtime-chosen executor, inject it explicitly
  (`App(executor=AsyncExecutor(n))`) so the App type stays concrete.
- **Scoped middleware is cheap.** `route!(...; middleware=(a, b))`,
  `group(...)`, and `use(...; paths=["/api"])` all run through the tuple
  pipeline; route-scoped middleware adds no allocation over an unscoped route.
- **DI is typed.** `App(services=(db=pool,))` sets a typed `Request` field;
  read it with `withservices(req) do svcs … end` for type-stable access.
- **Timeouts bound the client, not the handler.** `request_timeout_ms` answers
  `504` after the deadline, but Julia tasks cannot be killed: the handler keeps
  running and is tracked as a runaway. Once `max_bg_tasks` (default: 4×workers)
  runaways accumulate, new timed requests are shed with `503` +
  `Retry-After`. Make handlers self-bounding (DB/HTTP client timeouts,
  cancellation flags) for real resource limits; `mongoose_bg_tasks` exposes the
  runaway gauge.
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
SIGINT/SIGTERM drains in-flight requests and SSE streams, runs `onstop` hooks,
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

Mongoose ships a **trim-safe profile**: `@routes` declares the route table at
compile time (paths, capture types, methods, handlers are type parameters), so
dispatch has no runtime `apply_type`, no erased `Function` slots, and no dynamic
terminal. Both probes build with **0 verifier errors** and run:

- `bench/trim/trim_core.jl` — the full pipeline over `FakeTransport`
  (middleware, errors, typed params), self-checking exit codes.
- `bench/trim/trim_server.jl` — a real server on the C transport.

```sh
JULIA_APPS_JULIA_CMD=~/.julia/juliaup/julia-1.12.5+0.x64.linux.gnu/bin/julia \
~/.julia/bin/juliac --output-exe app --trim=safe --experimental \
  --project=/path/to/Mongoose.jl bench/trim/trim_server.jl
./app 8080 &            # serves; curl http://127.0.0.1:8080/
```

```julia
router = @routes begin
    get("/", req -> json((ok = true,)))
end
app = App(router = router)

function main(args)                 # canonical entry: `function main` + `@main`
    start!(app; host = "127.0.0.1", port = 8080, blocking = true)
    return 0                        # JuliaC calls exit(main(ARGS))
end
@main
```

Two constraints of the AOT profile (juliac/trim, not Mongoose):

- **No tasks.** Trimmed executables cannot run `@async`/`Threads.@spawn`
  (stale task world age), so `blocking = true` runs the event loop **inline**
  and the profile is sync-mode only: no async workers, streams, or
  `background` tasks.
- **No dynamic `Router`.** Runtime registration (`get!`/`route!`) is rejected by
  the verifier; use `@routes`/`StaticRouter`.

Static mounts (`serve!`) and `@routes` WebSocket endpoints are trim-safe:
mounts are concrete `(dir, prefix)` pairs served by the C helper, and WS
upgrades/messages resolve typed handlers with no Dict lookup. WS is sync-only
in AOT (the profile has no tasks). TLS is not trim-verified yet. The default
`Router` remains the JIT profile.
