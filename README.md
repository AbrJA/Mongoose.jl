<p align="center">
    <img width="220px" src="logo.png"/>
</p>

<h1 align="center">Mongoose.jl</h1>

<p align="center">
    <strong>Fast, lightweight HTTP &amp; WebSocket server for Julia</strong><br>
    Built on the battle-tested <a href="https://github.com/cesanta/mongoose">Mongoose C library</a>
</p>

<p align="center">
    <a href="https://AbrJA.github.io/Mongoose.jl/dev"><img src="https://img.shields.io/badge/docs-dev-blue.svg" alt="Documentation"/></a>
    <a href="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain"><img src="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main" alt="Build Status"/></a>
    <img src="https://img.shields.io/badge/Julia-1.10+-purple.svg" alt="Julia 1.10+"/>
    <img src="https://img.shields.io/badge/license-GPL--2-green.svg" alt="License"/>
</p>

---

## Why Mongoose.jl?

- **Minimal dependencies** — only `Mongoose_jll` and `PrecompileTools`. No HTTP.jl, no Sockets.jl.
- **Sub-100ms time to first response** — precompilation bakes the hot path into your sysimage.
- **Sync and async modes** — single-threaded for simplicity, multi-worker pool for production.
- **Trie-based router** — O(1) route matching with typed path parameters (`:id::Int`).
- **Battery-included middleware** — CORS, rate limiting, auth, logging, static files, health checks.
- **WebSocket support** — on the same port and router as HTTP.
- **AOT-ready** — full `juliac --trim=safe` compatibility for compiled binaries with zero startup time.
- **JSON as an extension** — `JSON.jl` is optional; loaded automatically when present.

---

## Installation

```julia
] add Mongoose
```

For JSON support:

```julia
] add JSON
```

---

## Quick Start

```julia
using Mongoose

router = Router()

route!(router, :get, "/", req -> Response(200, "Hello from Mongoose.jl!"))

route!(router, :get, "/users/:id::Int", (req, id) ->
    Response(200, ContentType.json, """{"id": $id, "name": "User $id"}""")
)

route!(router, :post, "/echo", req -> Response(200, req.body))

server = AsyncServer(router; workers=4)
start!(server, port=8080, blocking=false)

# Graceful shutdown when done
shutdown!(server)
```

---

## Routing

### HTTP Methods

```julia
route!(router, :get,    "/items",     req -> ...)
route!(router, :post,   "/items",     req -> ...)
route!(router, :put,    "/items/:id", (req, id) -> ...)
route!(router, :patch,  "/items/:id", (req, id) -> ...)
route!(router, :delete, "/items/:id", (req, id) -> ...)
```

GET routes automatically handle HEAD requests (body stripped).

### Typed Path Parameters

Append `::Type` to a segment for automatic parsing:

```julia
route!(router, :get, "/users/:id::Int",       (req, id)   -> ...)  # id::Int
route!(router, :get, "/price/:val::Float64",  (req, val)  -> ...)  # val::Float64
route!(router, :get, "/posts/:slug",          (req, slug) -> ...)  # slug::SubString
```

### Query String

```julia
route!(router, :get, "/search", req -> begin
    q    = query(req, "q")
    page = query(req, "page")

    q === nothing && return Response(400, "Missing ?q=")
    Response(200, "Searching: $q, page $(something(page, "1"))")
end)
```

Or parse a query string directly into a typed struct:

```julia
struct SearchParams
    q::String
    page::Int
    limit::Union{Int, Nothing}
end

# "q=julia&page=1" → SearchParams("julia", 1, nothing)
s = Mongoose.query(SearchParams, req.query)
```

### Request Helpers

| Expression | Returns | Description |
|---|---|---|
| `req.body` | `String` | Raw request body |
| `get(req.headers, "authorization", nothing)` | `String \| nothing` | Case-insensitive header lookup |
| `req.query` | `String` | Raw query string (e.g. `"q=test&page=2"`) |
| `getcontext!(req)` | `Dict{Symbol,Any}` | Lazily-allocated context dict (set by middleware) |

---

## Server Types

| Type | Model | Best for |
|---|---|---|
| `AsyncServer` | Event loop + N worker tasks via channels | Production APIs |
| `SyncServer` | Blocking event loop on caller's thread | Scripts, AOT binaries |

```julia
# Production: 4 workers, 5s per-request timeout, 4 MB body limit
server = AsyncServer(router;
    workers=4,
    nqueue=1024,
    request_timeout_ms=5000,
    max_body_size=4 * 1024 * 1024,
)

# AOT / simple scripts
server = SyncServer(router)
```

### Custom Error Responses

Register pre-built responses for specific status codes — no function callbacks, fully trim-safe:

```julia
error_response!(server, 500, Response(500, ContentType.json, """{"error":"Internal error"}"""))
error_response!(server, 413, Response(413, ContentType.json, """{"error":"Body too large"}"""))
error_response!(server, 504, Response(504, ContentType.json, """{"error":"Timed out"}"""))

# Custom 404 — add a catch-all route
route!(router, :get, "*", req -> Response(404, ContentType.html, read("404.html", String)))
```

---

## Responses

```julia
Response(200, "Hello!")                              # auto text/plain
Response(200, ContentType.json, """{"ok": true}""") # explicit Content-Type
Response(404, "Not found")
Response(204, "")
```

### ContentType Constants

```
ContentType.text   →  text/plain
ContentType.json   →  application/json
ContentType.html   →  text/html
ContentType.xml    →  application/xml
ContentType.css    →  text/css
ContentType.js     →  application/javascript
```

Headers can be concatenated: `ContentType.json * "X-Custom: value\r\n"`

---

## Middleware

Middleware runs in registration order. Each middleware can inspect and modify the request, short-circuit with a response, or pass through to the next handler.

```julia
server = AsyncServer(router)

# Structured JSON access logs
use!(server, logger(structured=true))

# CORS — allow a specific origin
use!(server, cors(origins="https://myapp.com"))

# Rate limiting — 200 requests per 60s per client IP
use!(server, rate_limit(max_requests=200, window_seconds=60))

# Auth — scoped to /api routes only
use!(server, bearer_token(token -> token == "my-secret"); paths=["/api"])

# API key auth
use!(server, api_key(header_name="X-API-Key", keys=Set(["key-abc", "key-xyz"])))

# Serve static files — GET /static/... → public/...
use!(server, static_files("public"; prefix="/static"))

# Built-in health check at GET /healthz
use!(server, health())
```

### Path-Scoped Middleware

The `paths` keyword limits a middleware to specific URL prefixes only:

```julia
use!(server, bearer_token(t -> t == "secret"); paths=["/api", "/admin"])
use!(server, rate_limit(max_requests=10);       paths=["/api/expensive"])
```

### Custom Middleware

Subtype `AbstractMiddleware` and implement the call operator:

```julia
struct RequestTimer <: Mongoose.AbstractMiddleware end

function (::RequestTimer)(req, params, next)
    t = time()
    res = next()
    elapsed = round((time() - t) * 1000, digits=1)
    @info "$(req.method) $(req.uri)" status=res.status ms=elapsed
    return res
end

use!(server, RequestTimer())
```

---

## WebSocket Support

```julia
ws!(router, "/chat",
    on_message = (msg::Message) -> begin
        # msg.data is String (text) or Vector{UInt8} (binary)
        Message("Echo: $(msg.data)")
    end,
    on_open  = (req::Request) -> @info "Client connected" uri=req.uri,
    on_close = ()             -> @info "Client disconnected"
)
```

Return `nothing` from `on_message` to send no reply. WebSocket endpoints share the same port and router as HTTP.

---

## JSON

Install `JSON.jl` and extend `render_body` once at startup:

```julia
using Mongoose, JSON

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)
```

Then use `Response(Json, value)` anywhere — Content-Type is set automatically:

```julia
route!(router, :get, "/users/:id::Int", (req, id) ->
    Response(Json, Dict("id" => id, "name" => "User $id"))
)

route!(router, :post, "/users", req -> begin
    data = JSON.parse(req.body)
    Response(Json, Dict("created" => get(data, "name", "")); status=201)
end)
```

---

## AOT Compilation with `juliac`

Use the `@router` macro to generate a **zero-allocation, compile-time dispatch function** — required for `juliac --trim=safe`. No dynamic dispatch, no closures, no allocations on the hot path.

```julia
# app.jl
using Mongoose

@router MyApp begin
    get("/",               req      -> Response(200, "Hello!"))
    get("/users/:id::Int", (req, id) -> Response(200, "User $id"))
    post("/echo",          req      -> Response(200, req.body))
    ws("/live", on_message = msg   -> Message("Echo: $(msg.data)"))
end

(@main)(ARGS) = begin
    server = SyncServer(MyApp)
    start!(server, port=8080, blocking=true)
    return 0
end
```

Compile and run:

```bash
juliac --trim=safe --project . --output-exe myapp app.jl
./myapp   # starts instantly — no JIT warmup
```

---

## Full Example

A complete app with REST API, WebSocket, middleware stack, and custom errors:

```julia
using Mongoose, JSON

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

router = Router()

# Health check
route!(router, :get, "/health", req -> Response(200, "ok"))

# REST API
route!(router, :get, "/api/users/:id::Int", (req, id) ->
    Response(Json, Dict("id" => id, "name" => "User $id"))
)

route!(router, :post, "/api/users", req -> begin
    data = JSON.parse(req.body)
    Response(Json, Dict("created" => get(data, "name", "")); status=201)
end)

# WebSocket
ws!(router, "/ws",
    on_message = (msg::Message) -> Message("""{"ack":true}"""),
    on_open    = (req::Request) -> @info "WS connected",
    on_close   = ()             -> @info "WS disconnected"
)

# Custom 404
route!(router, :get, "*", req -> Response(404, ContentType.html, "<h1>Not Found</h1>"))

# Server
server = AsyncServer(router; workers=4, request_timeout_ms=10_000)

use!(server, logger(structured=true))
use!(server, cors(origins="https://myapp.com"))
use!(server, rate_limit(max_requests=300, window_seconds=60))
use!(server, bearer_token(t -> t == ENV["API_TOKEN"]); paths=["/api"])
use!(server, static_files("public"; prefix="/static"))

error_response!(server, 500, Response(Json, Dict("error" => "Internal error"); status=500))

start!(server, port=8080, blocking=false)
@info "Listening on http://0.0.0.0:8080"

try
    wait()
catch e
    e isa InterruptException || rethrow()
finally
    shutdown!(server)
end
```

---

## Documentation

Full API reference and examples: **[AbrJA.github.io/Mongoose.jl](https://AbrJA.github.io/Mongoose.jl/dev)**

## License

Distributed under the GPL-2 License. See [`LICENSE`](LICENSE) for details.
