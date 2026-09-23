# Mongoose.jl

**Mongoose.jl** is a production-ready HTTP & WebSocket framework for Julia, built on the [Mongoose C library](https://github.com/cesanta/mongoose).

## Key Features

- **Modular, pluggable core** — `Router`, `Executor`, and `Transport` are
  replaceable components behind small protocols (`AbstractRouter`,
  `AbstractExecutor`, `AbstractTransport`)
- **Unified `App` type** — sync (`SyncExecutor`) or async worker pool (`AsyncExecutor`)
- **Built-in JSON** via JSON — `parsejson(req)` for parsing, `json(...)` for responses
- **Typed routing** — exact `Dict` lookup + ordered parametric patterns,
  typed path parameters (`:id::Int`) as typed tuples, wildcards, route groups;
  `freeze!` compiles a closed route table into statically-typed dispatch
  (the foundation for AOT builds; `juliac --trim` support is still in
  progress)
- **Full middleware stack** — CORS, rate limiting, bearer/API-key/basic auth,
  access logs, Prometheus metrics (counters, histogram, live gauges), health
  checks, security headers, gzip, ETag
- **Real-time** — WebSocket (origin allowlist, idle timeout, server push via
  `broadcastws`) and Server-Sent Events (`sse` / `emit`) on the same port
- **Native TLS** — HTTPS via `TLSConfig`
- **Production-ready** — graceful shutdown (SIGINT; SIGTERM/exit via `atexit`),
  backpressure, request/header timeouts, connection caps, custom + typed
  errors, dependency injection, background tasks
- **Testable without FFI** — `FakeTransport` runs the whole pipeline without
  `Mongoose_jll`

## Installation

```julia
] add Mongoose
```

## Quick Start

```julia
using Mongoose

app = App(workers=4)

get!(app, "/") do req
    text("Hello, World!")
end

get!(app, "/users/:id::Int") do req, id
    json(Dict("id" => id, "name" => "User $id"))
end

post!(app, "/users") do req
    data = parsejson(req)
    json(Dict("created" => data["name"]); status=201)
end

start!(app; port=8080)
```

## Architecture

Mongoose.jl is layered so each boundary is a replacement point:

```
┌──────────────────────────────────────────┐
│  App (config, lifecycle, services)       │
│    + Router   <: AbstractRouter          │
│    + Executor <: AbstractExecutor        │
├──────────────────────────────────────────┤
│  Pipeline (process) & Middleware         │
├──────────────────────────────────────────┤
│  Kernel (protocol, router, types)        │
├──────────────────────────────────────────┤
│  Transport (<: AbstractTransport)        │
│    - C transport (Mongoose FFI)          │
│    - FakeTransport (no FFI, for tests)   │
└──────────────────────────────────────────┘
```

- **Router** registers `Endpoint`s (handler + scoped middleware + metadata) and resolves matches; it never runs handlers.
  After `freeze!` it compiles the closed table: per-route terminals are pre-baked
  (handler + scoped middleware fused, handler type captured) and parametric
  matching runs through a statically-typed chain with no per-request path split.
- **App** composes a router, an executor, middleware, and lifecycle.
- **SyncExecutor** runs jobs inline; **AsyncExecutor** is a bounded worker pool.
- The request→response seam (`process`) lives in `Kernel` and works with no server and no FFI.

## Units

Quantities carry their unit in the name: `_ms` for timeouts (`request_timeout_ms`,
`logger(threshold_ms=…)`), `_seconds` for protocol durations (`window_seconds`,
`cors(max_age_seconds=…)`), `_bytes` for sizes (`max_body_bytes`,
`compress(min_size_bytes=…)`). Standard protocol fields keep their spec names
(`Cookie(; max_age=…)` is `Max-Age` in seconds). Optional headers/values are
turned off with `nothing`.

## Next Steps

- [Examples](@ref) — cookbook-style recipes for common patterns
- [API Reference](@ref) — full documentation of all exported types and functions
