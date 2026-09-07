# Mongoose.jl

**Mongoose.jl** is a production-ready HTTP & WebSocket framework for Julia, built on the [Mongoose C library](https://github.com/cesanta/mongoose).

## Key Features

- **Modular, pluggable core** — `Router`, `Executor`, and `Transport` are
  replaceable components behind small protocols (`AbstractRouter`,
  `AbstractExecutor`, `AbstractTransport`)
- **Unified `App` type** — sync (`SyncExecutor`) or async worker pool (`AsyncExecutor`)
- **Built-in JSON** via JSON — `json(req)` for parsing, `json(...)` for responses
- **Typed routing** — exact `Dict` lookup + ordered parametric patterns,
  typed path parameters (`:id::Int`) as typed tuples, wildcards, route groups
- **Full middleware stack** — CORS, rate limiting, auth, logging, metrics, health, security, compression
- **WebSocket** — same port, frame limits, idle timeout, origin allowlist, upgrade rejection, ping/pong
- **SSE** — Server-Sent Events with `sse()` / `emit()`
- **Native TLS** — HTTPS via `TLSConfig`
- **Production-ready** — graceful shutdown, backpressure, custom + typed errors, DI, background tasks
- **Testable without FFI** — `FakeTransport` (aka `TestClient`) runs the whole pipeline without `Mongoose_jll`

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
    data = json(req)
    json(Dict("created" => data["name"]); status=201)
end

start!(app; port=8080)
```

## Architecture

Mongoose.jl is layered so each boundary is a replacement point:

```
┌──────────────────────────────────────────┐
│  App (config, lifecycle, services)       │
│    + Router  <: AbstractRouter           │
│    + Executor <: AbstractExecutor        │
├──────────────────────────────────────────┤
│  Pipeline (invoke_request) & Middleware  │
├──────────────────────────────────────────┤
│  MongooseCore (protocol, router, types)  │
├──────────────────────────────────────────┤
│  Transport (<: AbstractTransport)        │
│    - MongooseTransport (C FFI, default)  │
│    - FakeTransport (no FFI, for tests)   │
└──────────────────────────────────────────┘
```

- **Router** registers `Endpoint`s (handler + scoped middleware + metadata) and resolves matches; it never runs handlers.
- **App** composes a router, an executor, middleware, and lifecycle.
- **SyncExecutor** runs jobs inline; **AsyncExecutor** is a bounded worker pool.
- The request→response seam (`invoke_request`) lives in `MongooseCore` and works with no server and no FFI.

## Next Steps

- [Examples](@ref) — cookbook-style recipes for common patterns
- [API Reference](@ref) — full documentation of all exported types and functions
