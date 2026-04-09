<p align="center">
    <img width="220px" src="logo.png"/>
</p>

<h1 align="center">Mongoose.jl</h1>

<p align="center">
    <strong>Production-ready HTTP &amp; WebSocket framework for Julia</strong><br>
    Built on the battle-tested <a href="https://github.com/cesanta/mongoose">Mongoose C library</a>
</p>

<p align="center">
    <a href="https://AbrJA.github.io/Mongoose.jl/dev"><img src="https://img.shields.io/badge/docs-dev-blue.svg" alt="Documentation"/></a>
    <a href="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain"><img src="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main" alt="Build Status"/></a>
    <img src="https://img.shields.io/badge/Julia-1.10+-purple.svg" alt="Julia 1.10+"/>
    <img src="https://img.shields.io/badge/license-GPL--2-green.svg" alt="License"/>
</p>

---

## Why Mongoose.jl? 🚀

| Category | Highlights |
|---|---|
| **Performance** | Sub-100ms TTFR via precompilation. Zero-allocation static router. C-level static file serving with Range, ETag, gzip. |
| **Architecture** | Sync (`Server`) and async (`Async`) modes. Multi-worker pool with backpressure. Per-request timeouts with thread starvation protection. |
| **Routing** | Trie-based O(1) matching. Typed path parameters (`:id::Int`). Wildcards (`*path`). Automatic HEAD from GET handlers. |
| **WebSocket** | Same port as HTTP. Frame size limits. Idle timeout. Upgrade rejection. Ping/pong (RFC 6455). |
| **Middleware** | CORS, rate limiting, bearer/API key auth, structured logging, Prometheus metrics, health checks. Path-scoped via `paths=`. |
| **Production** | Graceful shutdown with drain. 503 backpressure on overload. Custom error responses. `X-Request-Id` propagation. |
| **AOT** | Full `juliac --trim=safe` support via `@router` macro. Zero startup time compiled binaries. |
| **Minimal** | Only `Mongoose_jll` + `PrecompileTools`. No HTTP.jl, no Sockets.jl. JSON via optional one-line extension (see [JSON](#json)). |

---

## Installation 📦

```julia
] add Mongoose
```

For JSON support:

```julia
] add JSON
```

---

## Quick Start ⚡

```julia
using Mongoose

router = Router()

route!(router, :get, "/", req -> Response(Plain, "Hello from Mongoose.jl!"))

route!(router, :get, "/users/:id::Int", (req, id) ->
    Response(Json, """{"id": $id, "name": "User $id"}""")
)

route!(router, :post, "/echo", req -> Response(Plain, req.body))

server = Async(router; nworkers=4)
start!(server, port=8080, blocking=false)

# Graceful shutdown when done
shutdown!(server)
```

---

## Routing 🧭

### HTTP Methods 🌐

```julia
route!(router, :get,    "/items",     req -> ...)
route!(router, :post,   "/items",     req -> ...)
route!(router, :put,    "/items/:id", (req, id) -> ...)
route!(router, :patch,  "/items/:id", (req, id) -> ...)
route!(router, :delete, "/items/:id", (req, id) -> ...)
```

GET routes automatically handle HEAD requests (body stripped, headers preserved).

### Typed Path Parameters 🔢

Append `::Type` to a segment for automatic parsing. Invalid values return 404 (e.g. `/users/abc` when `Int` is expected):

```julia
route!(router, :get, "/users/:id::Int",       (req, id)   -> ...)  # id::Int
route!(router, :get, "/price/:val::Float64",  (req, val)  -> ...)  # val::Float64
route!(router, :get, "/posts/:slug",          (req, slug) -> ...)  # slug::String
```

### Query String 🔍

Define a struct and parse the whole query string at once:

```julia
struct SearchParams
    q::String
    page::Int
    limit::Union{Int, Nothing}
end

route!(router, :get, "/search", req -> begin
    p = Mongoose.query(SearchParams, req)  # parses ?q=julia&page=2
    Response(Plain, "Searching: $(p.q), page $(p.page)")
end)
```

Missing fields default to `""`, `0`, `false`, or `nothing` depending on their type.

### Request Helpers 🛠️

| Expression | Returns | Description |
|---|---|---|
| `req.body` | `String` | Raw request body |
| `get(req.headers, "authorization", nothing)` | `String \| nothing` | Case-insensitive header lookup |
| `req.query` | `String` | Raw query string (e.g. `"q=test&page=2"`) |
| `Mongoose.query(T, req)` | `T` | Parse query string into struct `T` |
| `context!(req)` | `Dict{Symbol,Any}` | Lazily-allocated context dict (set by middleware) |

---

## Server Types 🖥️

| Type | Model | Best for |
|---|---|---|
| `Async` | Event loop + N worker tasks via channels | Production APIs |
| `Server` | Blocking event loop on caller's thread | Scripts, AOT binaries |

```julia
# Production: 4 workers, 5s per-request timeout, 4 MB body limit, 60s WS idle timeout
server = Async(router;
    nworkers        = 4,
    nqueue          = 1024,
    request_timeout = 5000,
    max_body        = 4 * 1024 * 1024,
    ws_idle_timeout = 60,
)

# AOT / simple scripts
server = Server(router)
```

### Config ⚙️

Consolidate all options into a `Config` struct — particularly useful for environment-driven configuration:

```julia
config = Config(
    nworkers        = parse(Int, get(ENV, "NWORKERS", "4")),
    max_body        = parse(Int, get(ENV, "MAX_BODY", "1048576")),
    request_timeout = parse(Int, get(ENV, "REQ_TIMEOUT", "0")),
    ws_idle_timeout = 60,
    drain_timeout   = 10_000,
)

server = Async(router, config)   # or Server(router, config)
```

### Custom Error Responses 🧯

Register pre-built responses for specific status codes — no function callbacks, fully trim-safe:

```julia
fail!(server, 500, Response(Json, """{"error":"Internal error"}"""; status=500))
fail!(server, 413, Response(Json, """{"error":"Body too large"}"""; status=413))
fail!(server, 503, Response(Json, """{"error":"Service overloaded"}"""; status=503))
fail!(server, 504, Response(Json, """{"error":"Timed out"}"""; status=504))

# Custom 404 — add a catch-all route
route!(router, :get, "*", req -> Response(Html, read("404.html", String); status=404))
```

---

## Responses 📬

```julia
Response(Plain, "Hello!")                    # text/plain, status 200
Response(Json, """{"ok": true}""")          # application/json, status 200
Response(Html, "<p>ok</p>")                 # text/html, status 200
Response(Json, body; status=201)            # custom status
Response(Html, body; status=404)            # custom status
Response(Json, body; headers=["X-Custom" => "value"])  # extra headers
```

The format type sets the `Content-Type` header automatically:

| Format | Content-Type |
|---|---|
| `Plain` | `text/plain; charset=utf-8` |
| `Html` | `text/html; charset=utf-8` |
| `Json` | `application/json; charset=utf-8` |
| `Xml` | `application/xml; charset=utf-8` |
| `Css` | `text/css; charset=utf-8` |
| `Js` | `application/javascript; charset=utf-8` |
| `Binary` | `application/octet-stream` |

---

## Middleware 🧩

Middleware runs in registration order. Each middleware can inspect and modify the request, short-circuit with a response, or pass through to the next handler.

```julia
server = Async(router)

# Structured JSON access logs
plug!(server, logger(structured=true))

# CORS — allow a specific origin
plug!(server, cors(origins="https://myapp.com"))

# Rate limiting — 200 requests per 60s per client IP
plug!(server, ratelimit(max_requests=200, window_seconds=60))

# Auth — scoped to /api routes only
plug!(server, bearer(token -> token == "my-secret"); paths=["/api"])

# API key auth
plug!(server, apikey(header_name="X-API-Key", keys=Set(["key-abc", "key-xyz"])))

# Serve static files from the "public/" directory (C-level, with Range/ETag/gzip)
mount!(server, "public")

# Prometheus-compatible metrics at GET /metrics
plug!(server, metrics())

# Built-in health check at GET /healthz
plug!(server, health())
```

### Path-Scoped Middleware 🎯

The `paths` keyword limits a middleware to specific URL prefixes only:

```julia
plug!(server, bearer(t -> t == "secret"); paths=["/api", "/admin"])
plug!(server, ratelimit(max_requests=10);       paths=["/api/expensive"])
```

### Custom Middleware 🧪

Subtype `AbstractMiddleware` and implement the call operator:

```julia
struct RequestTimer <: Mongoose.AbstractMiddleware end

function (::RequestTimer)(req::Request, params, next)
    t = time()
    res = next()
    elapsed = round((time() - t) * 1000, digits=1)
    @info "$(req.method) $(req.uri)" status=res.status ms=elapsed
    return res
end

plug!(server, RequestTimer())
```

---

## WebSocket Support 🔌

```julia
ws!(router, "/chat",
    on_message = (msg::Message) -> Message("Echo: $(msg.data)"),
    on_open    = (req::Request) -> begin
        # Return false to reject the upgrade (sends 403)
        auth = get(req.headers, "authorization", nothing)
        auth === nothing && return false
        @info "WS connected" uri=req.uri
    end,
    on_close   = () -> @info "WS disconnected"
)
```

| Callback | Signature | Notes |
|---|---|---|
| `on_open` | `(req::Request) → Any` | Return `false` to reject upgrade with 403. Optional. |
| `on_message` | `(msg::Message) → Message \| String \| Vector{UInt8} \| nothing` | Called per frame. Return `nothing` for no reply. |
| `on_close` | `() → Any` | No arguments — connection is already gone. Optional. |

**Production features:**
- **Frame size limit** — enforced via `max_body` (same limit as HTTP). Oversized frames close the connection.
- **Idle timeout** — set `ws_idle_timeout` (seconds) to auto-close stale connections.
- **Upgrade rejection** — return `false` from `on_open` to refuse the connection with 403.
- **Ping/pong** — automatic RFC 6455 control frame handling.

💡 **Tip:** start with `ws_idle_timeout=60` and tune based on your client behavior.

---

## JSON 🧾

Install `JSON.jl` and extend `encode` once at startup:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)
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

## AOT Compilation with `juliac` 🧊

Use the `@router` macro to generate a **zero-allocation, compile-time dispatch function** — required for `juliac --trim=safe`. No dynamic dispatch, no closures, no allocations on the hot path.

```julia
# app.jl
using Mongoose

@router MyApp begin
    get("/", req -> Response(Plain, "Hello!"))
    get("/users/:id::Int", (req, id) -> Response(Plain, "User $id"))
    post("/echo", req -> Response(Plain, req.body))
    ws("/live", on_message = msg -> Message("Echo: $(msg.data)"))
end

(@main)(ARGS) = begin
    server = Server(MyApp)
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

## Full Example 🏗️

A complete app with REST API, WebSocket, middleware stack, and custom errors:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

router = Router()

# Health check
route!(router, :get, "/health", req -> Response(Plain, "ok"))

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
    on_open = (req::Request) -> @info "WS connected" uri=req.uri,
    on_close = () -> @info "WS disconnected"
)

# Custom 404
route!(router, :get, "*", req -> Response(Html, "<h1>Not Found</h1>"; status=404))

# Server
server = Async(router; nworkers=4, request_timeout=10_000, ws_idle_timeout=60)

plug!(server, logger(structured=true))
plug!(server, cors(origins="https://myapp.com"))
plug!(server, ratelimit(max_requests=30, window_seconds=60))
plug!(server, bearer(t -> t == get(ENV, "API_TOKEN", "secret")); paths=["/api"])
mount!(server, "public")

fail!(server, 500, Response(Json, Dict("error" => "Internal error"); status=500))

# blocking=true: start! handles Ctrl+C automatically and shuts down gracefully
start!(server, port=8080)
```

---

## Documentation 📚

Full API reference and examples: **[AbrJA.github.io/Mongoose.jl](https://AbrJA.github.io/Mongoose.jl/dev)**

## License ⚖️

Distributed under the GPL-2 License. See [`LICENSE`](LICENSE) for details.
