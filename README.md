[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://AbrJA.github.io/Mongoose.jl/dev)
[![Build Status](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain)

<p align="center">
    <img width="300px" src="logo.png"/>
</p>

# Mongoose.jl

**Mongoose.jl** is a lightweight, high-performance HTTP & WebSocket server for Julia, built on the [Mongoose C library](https://github.com/cesanta/mongoose). It features a minimal dependency footprint (only `Mongoose_jll` + `PrecompileTools`), sub-100ms time-to-first-response via precompilation, and full compatibility with `juliac --trim=safe` for ahead-of-time compiled binaries.

## Installation

```julia
] add Mongoose
```

For JSON support, also install `JSON.jl` — it will be loaded automatically as a package extension:

```julia
] add JSON
```

## Quick Start

```julia
using Mongoose

# Define routes on a Router
router = Router()

route!(router, :get, "/", req -> Response(200, ContentType.text, "Hello from Mongoose.jl!"))

route!(router, :get, "/users/:id::Int", (req, id) -> begin
    Response(200, ContentType.json, """{"id": $id}""")
end)

# Create an async server with 4 worker threads
server = AsyncServer(router; workers=4)
start!(server, port=8080, blocking=false)

# ... later
shutdown!(server)
```

## Architecture

Mongoose.jl uses a **decoupled** design: routes live on a `Router`, and the `Server` handles networking and concurrency.

```
Router (defines routes)  ──►  Server (runs event loop)
                                 │
                         ┌───────┼───────┐
                         ▼       ▼       ▼
                      Worker  Worker  Worker   (AsyncServer only)
```

### Server Types

| Type | Concurrency | Use Case |
|------|-------------|----------|
| `AsyncServer(router; workers=4)` | Background worker pool via channels | Production apps, APIs |
| `SyncServer(router)` | Main-thread event loop (blocking) | Scripts, AOT binaries |

Both accept these keyword arguments:

```julia
AsyncServer(router;
    workers=4,              # Number of worker tasks
    nqueue=1024,            # Channel buffer size
    timeout=0,              # Poll timeout (ms), 0 = default
    max_body_size=1048576,  # Max request body (bytes, default 1MB)
    drain_timeout_ms=5000   # Graceful shutdown drain timeout
)

SyncServer(router;
    timeout=0,
    max_body_size=1048576,
    drain_timeout_ms=5000
)
```

### Routing

Routes can use Symbol or String methods, and support typed path parameters:

```julia
router = Router()

# Symbol method
route!(router, :get, "/hello", req -> Response(200, ContentType.text, "hi"))

# Other HTTP methods
route!(router, :post, "/data", req -> Response(200, ContentType.text, "ok"))

# Path parameters with type annotations
route!(router, :get, "/users/:name", (req, name) -> ...)           # name::String
route!(router, :get, "/items/:id::Int", (req, id) -> ...)          # id::Int
route!(router, :get, "/price/:val::Float64", (req, val) -> ...)    # val::Float64

# Routes can also be added directly on a server
route!(server, :get, "/health", req -> Response(200, ContentType.text, "ok"))
```

GET routes automatically respond to HEAD requests.

### ContentType Headers

Pre-formatted Content-Type headers are available via the `ContentType` constant:

```julia
ContentType.text   # text/plain
ContentType.json   # application/json
ContentType.html   # text/html
ContentType.xml    # application/xml
ContentType.css    # text/css
ContentType.js     # application/javascript
```

### Request Helpers

```julia
route!(router, :post, "/search", req -> begin
    req.body                              # Raw body string
    get(req.headers, "authorization", nothing)  # Case-insensitive header lookup
    req.query                             # Full query string
    req.context                           # Dict{Symbol,Any} for middleware data

    # Parse query string into a struct
    struct Search; q::String; page::Int end
    s = Mongoose.query(Search, req.query)  # "q=julia&page=1" → Search("julia", 1)

    Response(200, ContentType.text, "ok")
end)
```

### WebSocket Support

```julia
ws!(router, "/chat",
    on_message = msg -> "Echo: $(msg.data)",
    on_open    = () -> println("Client connected"),
    on_close   = () -> println("Client disconnected")
)
```

Message handlers receive `WsTextMessage` or `WsBinaryMessage`. Return a `String` to send a text reply, `Vector{UInt8}` for binary, or `nothing` to send no reply.

### Middleware

Built-in middleware is added with `use!` and runs in registration order:

```julia
server = AsyncServer(router)

# Request/response logging (logs method, URI, status, duration)
use!(server, logger(threshold_ms=100))      # Only log requests slower than 100ms

# CORS headers + OPTIONS preflight handling
use!(server, cors(origins="https://example.com", max_age=86400))

# Rate limiting (fixed-window per client IP)
use!(server, rate_limit(max_requests=100, window_seconds=60))

# Authentication
use!(server, bearer_token(token -> token == "secret-123"))
use!(server, api_key(header_name="X-API-Key", keys=Set(["key1", "key2"])))

# Static file serving
use!(server, static_files("public"; prefix="/static", index="index.html"))
```

### JSON

JSON support requires `JSON.jl`. Extend `render_body` once at startup to enable `Response(Json, ...)` throughout your app:

```julia
using Mongoose, JSON

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

route!(router, :get, "/api/data", req -> begin
    Response(200, ContentType.json, JSON.json(Dict("ok" => true)))
end)

# Or with the Json format type shorthand:
route!(router, :get, "/api/users", req -> begin
    Response(Json, Dict("users" => ["Alice", "Bob"]))  # auto Content-Type
end)
```

### Static Router (AOT Compilation)

The `@router` macro generates a zero-allocation, compile-time dispatch function compatible with `juliac --trim=safe`:

```julia
@router MyApi begin
    get("/", req -> Response(200, ContentType.text, "Hello"))
    get("/users/:id::Int", (req, id) -> Response(200, ContentType.text, "User $id"))
    post("/data", req -> Response(200, ContentType.text, "received"))
    ws("/chat", on_message = msg -> "Echo: $(msg.data)")
end

server = SyncServer(MyApi())
start!(server, port=8080)
```

## Documentation

Full documentation with more examples is available at [AbrJA.github.io/Mongoose.jl](https://AbrJA.github.io/Mongoose.jl/dev).

## License

Distributed under the GPL-2 License. See `LICENSE` for details.
