# Mongoose.jl

**Mongoose.jl** is a production-ready HTTP & WebSocket framework for Julia, built on the [Mongoose C library](https://github.com/cesanta/mongoose).

## Key Features

- **Unified `App` type** — sync (`workers=0`) or async worker pool (`workers=N`)
- **Built-in JSON** via JSON — `body(req)` for parsing, `json(...)` for responses
- **Trie-based routing** — O(1) matching, typed path parameters, wildcards, route groups
- **Full middleware stack** — CORS, rate limiting, auth, logging, metrics, health, security, compression
- **WebSocket** — same port, frame limits, idle timeout, upgrade rejection, ping/pong
- **SSE** — Server-Sent Events with `sse()` / `emit()`
- **Native TLS** — HTTPS via `TLSConfig`
- **Production-ready** — graceful shutdown, backpressure, custom errors, DI, background tasks
- **Fast startup** — sub-100ms TTFR via `PrecompileTools`

## Installation

```julia
] add Mongoose
```

## Quick Start

```julia
using Mongoose

router = Router()

route!(router, :get, "/", req -> text("Hello, World!"))

route!(router, :get, "/users/:id::Int", (req, id) ->
    json(Dict("id" => id, "name" => "User $id"))
)

route!(router, :post, "/users", req -> begin
    data = body(req)  # parses JSON automatically
    json(Dict("created" => data["name"]); status=201)
end)

app = App(; router=router, workers=4)
start!(app; port=8080)
```

## Architecture

Mongoose.jl uses a layered architecture:

```
┌──────────────────────────────────────────┐
│  App (configuration, lifecycle, DI)      │
├──────────────────────────────────────────┤
│  Middleware Pipeline (onion model)       │
├──────────────────────────────────────────┤
│  Router (trie-based, groups)             │
├──────────────────────────────────────────┤
│  Protocol (Request, Response, formats)   │
├──────────────────────────────────────────┤
│  Transport (Mongoose C library FFI)      │
└──────────────────────────────────────────┘
```

- **Router** defines routes, handlers, and WebSocket endpoints
- **App** wraps the router with configuration, middleware, and lifecycle management
- `workers=0` runs the event loop on the calling thread (sync mode)
- `workers=N` spawns N worker tasks to process requests via channels (async mode)

## Next Steps

- [Examples](@ref) — cookbook-style recipes for common patterns
- [API Reference](@ref) — full documentation of all exported types and functions
