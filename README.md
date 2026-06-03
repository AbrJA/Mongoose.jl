<p align="center">
    <img width="220px" src="logo.png"/>
</p>

<h1 align="center">Mongoose.jl</h1>

<p align="center">
    <strong>Production-ready HTTP & WebSocket framework for Julia</strong><br>
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

| Category | Highlights |
|---|---|
| **Performance** | Sub-100ms TTFR via precompilation. C-level static file serving with Range, ETag, gzip. |
| **Architecture** | Unified `App` type: sync (`workers=0`) or async worker pool (`workers=N`). Backpressure and per-request timeouts. |
| **HTTPS/TLS** | Native TLS via `TLSConfig` — cert, key, CA as files, PEM strings, or raw bytes. |
| **Routing** | Trie-based O(1) matching. Typed path parameters (`:id::Int`). Wildcards (`*path`). Route groups with scoped middleware. |
| **WebSocket** | Same port as HTTP. Frame size limits. Idle timeout. Upgrade rejection. Ping/pong (RFC 6455). |
| **Middleware** | CORS, rate limiting, bearer/API key auth, structured logging, Prometheus metrics, health checks, security headers, GZip compression. |
| **JSON** | Built-in JSON serialization via JSON. `body(req)` for parsing, `json(...)` for responses. Zero config. |
| **Production** | Graceful shutdown with drain. 503 backpressure on overload. Custom error responses. Background tasks. Dependency injection. |

---

## Installation

```julia
] add Mongoose
```

---

## Quick Start

```julia
using Mongoose

app = App(workers=4)

route!(app.router, :get, "/", req -> text("Hello from Mongoose.jl!"))

route!(app.router, :get, "/users/:id::Int", (req, id) ->
    json(Dict("id" => id, "name" => "User $id"))
)

route!(app.router, :post, "/echo", req -> begin
    data = body(req)  # auto-parses JSON
    json(data; status=201)
end)

start!(app; port=8080)
```

---

## Routing

### HTTP Methods

```julia
router = Router()

route!(router, :get,    "/items",     req -> ...)
route!(router, :post,   "/items",     req -> ...)
route!(router, :put,    "/items/:id", (req, id) -> ...)
route!(router, :patch,  "/items/:id", (req, id) -> ...)
route!(router, :delete, "/items/:id", (req, id) -> ...)
```

GET routes automatically handle HEAD requests (body stripped, headers preserved).

### Typed Path Parameters

Append `::Type` to a segment for automatic parsing. Invalid values return 404:

```julia
route!(router, :get, "/users/:id::Int",       (req, id)   -> ...)  # id::Int
route!(router, :get, "/price/:val::Float64",  (req, val)  -> ...)  # val::Float64
route!(router, :get, "/posts/:slug",          (req, slug) -> ...)  # slug::String
route!(router, :get, "/files/*path",          (req, path) -> ...)  # wildcard catch-all
```

### Query Parameters

Use the `query()` helper for type-safe access with defaults:

```julia
route!(router, :get, "/search", req -> begin
    q     = query(req, "q", "")         # String with default
    page  = query(req, "page", 1)       # Auto-parsed to Int
    limit = query(req, "limit", 10)     # Auto-parsed to Int
    json(Dict("query" => q, "page" => page, "limit" => limit))
end)
```

### Route Groups

Organize routes under a shared prefix with scoped middleware:

```julia
api = group("/api/v1", middleware=[
    ratelimit(max_requests=100, window_seconds=60),
    apikey(header_name="x-api-key", keys=Set(["key-abc"])),
])

route!(api, :get,  "/users",     list_users)
route!(api, :post, "/users",     create_user)
route!(api, :get,  "/users/:id", get_user)

# Nested groups
group!(api, "/admin", middleware=[bearer(t -> t == "admin-token")]) do admin
    route!(admin, :delete, "/users/:id::Int", delete_user)
end

mount!(router, api)
```

---

## Request & Response

### Request Helpers

| Expression | Returns | Description |
|---|---|---|
| `body(req)` | `Any` | Parse JSON body (Dict, Array, etc.) |
| `body(req, MyStruct)` | `MyStruct` | Typed deserialization via StructTypes |
| `query(req, "key")` | `String` | Query parameter (throws if missing) |
| `query(req, "key", default)` | `typeof(default)` | Query param with auto-parsing |
| `multipart(req)` | `Vector{MultipartFile}` | Parse multipart form data |
| `get(req.headers, "name", nothing)` | `String \| nothing` | Case-insensitive header lookup |
| `req.uri` | `String` | Full request URI |
| `req.method` | `Symbol` | `:get`, `:post`, etc. |
| `ctx!(req)` | `Dict{Symbol,Any}` | Lazily-allocated context dict |

### Response Helpers

```julia
# Typed format responses
json(Dict("ok" => true))                    # 200, application/json
json(data; status=201)                      # custom status
json(data; headers=["X-Custom" => "val"])   # extra headers

text("Hello!")                              # 200, text/plain
html("<h1>Hi</h1>")                        # 200, text/html
redirect("/new-location")                   # 302
redirect("/new", 301)                       # 301

# Low-level Response constructor
Response(Json, """{"raw": true}""")         # pre-serialized JSON string
Response(Plain, "hello"; status=200)
Response(200, "OK"; headers=["X-H" => "v"])
```

### Content Formats

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

## App Configuration

```julia
app = App(;
    workers         = 4,          # Worker threads (0 = sync mode)
    queuesize       = 1024,       # Max pending requests (async)
    max_body        = 1_048_576,  # 1 MB max request body
    request_timeout = 5000,       # 5s per-request timeout (0 = disabled)
    drain_timeout   = 5000,       # Graceful shutdown drain (ms)
    ws_max_frame    = 1_048_576,  # Max WebSocket frame size
    ws_idle_timeout = 60_000,     # WS idle timeout (ms, 0 = disabled)
    router          = Router(),   # Custom router instance
    tls             = nothing,    # TLSConfig for HTTPS
)
```

### HTTPS / TLS

```julia
app = App(;
    router = router,
    tls = TLSConfig(
        cert = "certs/server.crt",
        key  = "certs/server.key",
    ),
)
start!(app; port=8443)
```

### Custom Error Responses

```julia
onerror!(app, 404) do req, status
    json(Dict("error" => "Not found", "path" => req.uri); status=404)
end

onerror!(app, 500, json(Dict("error" => "Internal Server Error"); status=500))
onerror!(app, 413, json(Dict("error" => "Request body too large"); status=413))
```

---

## Middleware

Middleware runs in registration order. Each middleware can inspect/modify the request, short-circuit, or pass to the next handler.

```julia
app = App(; router=router, workers=4)

# Security headers (OWASP best practices)
use!(app, security())

# Health checks (Kubernetes-ready: /healthz, /readyz, /livez)
use!(app, health())

# Prometheus metrics at GET /metrics
use!(app, metrics())

# CORS
use!(app, cors(origins="https://myapp.com", methods="GET, POST, PUT, DELETE"))

# GZip compression (responses > 1KB)
use!(app, compress(min_size=1024))

# Structured JSON access logs
use!(app, logger())

# Rate limiting — 200 requests per 60s per client IP
use!(app, ratelimit(max_requests=200, window_seconds=60))

# Bearer token auth — scoped to /api routes only
use!(app, bearer(token -> token == ENV["API_TOKEN"]); paths=["/api"])

# API key auth
use!(app, apikey(header_name="x-api-key", keys=Set(["key-abc", "key-xyz"])))

# Static file serving (C-level, with Range/ETag/gzip)
serve!(app, "public"; uri_prefix="/static")
```

### Custom Middleware

Subtype `AbstractMiddleware` and implement the call operator:

```julia
struct RequestTimer <: Mongoose.AbstractMiddleware end

function (::RequestTimer)(req::Request, next::Function)
    t = time()
    res = next()
    elapsed = round((time() - t) * 1000, digits=1)
    @info "$(req.method) $(req.uri)" status=res.status ms=elapsed
    return res
end

use!(app, RequestTimer())
```

---

## WebSocket

```julia
ws!(router, "/chat";
    on_open = (req::Request) -> begin
        # Return false to reject upgrade with 403
        auth = get(req.headers, "authorization", nothing)
        auth === nothing && return false
        @info "WS connected" uri=req.uri
        true
    end,
    on_message = (msg::Message) -> Message("Echo: $(msg.data)"),
    on_close = () -> @info "WS disconnected"
)
```

| Callback | Signature | Notes |
|---|---|---|
| `on_open` | `(req) → Any` | Return `false` to reject with 403. Optional. |
| `on_message` | `(msg) → Message \| nothing` | Called per frame. Return `nothing` for no reply. |
| `on_close` | `() → Any` | Connection already gone. Optional. |

---

## Server-Sent Events (SSE)

Push real-time events to clients:

```julia
route!(router, :get, "/events", req ->
    sse(req) do writer
        for i in 1:10
            emit(writer; data="Tick $i", event="update", id=string(i))
            sleep(1)
        end
    end
)
```

`sse()` returns a `StreamResponse` with correct SSE headers. `emit()` formats each event per the W3C EventSource spec.

---

## JSON (Built-in)

JSON serialization is built-in via JSON — no extension needed:

```julia
# Response helpers
json(Dict("id" => 1, "name" => "Alice"))
json(["a", "b", "c"]; status=200)

# Request body parsing
route!(router, :post, "/users", req -> begin
    data = body(req)  # parses JSON body → Dict/Array
    json(Dict("created" => data["name"]); status=201)
end)

# Typed deserialization (requires StructTypes)
using StructTypes

struct User
    name::String
    age::Int
end
StructTypes.StructType(::Type{User}) = StructTypes.Struct()

route!(router, :post, "/users", req -> begin
    user = body(req, User)  # deserializes JSON → User
    json(Dict("hello" => user.name))
end)
```

---

## Dependency Injection

```julia
app = App(; router=router, workers=4)

# Register services
service!(app, :db, connect_to_database())
service!(app, :cache, RedisPool())

# Access in handlers
route!(router, :get, "/users", req -> begin
    db = service(req, :db)
    users = fetch_users(db)
    json(users)
end)
```

---

## Background Tasks & Lifecycle Hooks

```julia
# Run a function when the server starts
onstart!(app) do
    @info "Server started"
    seed_database!()
end

# Run during graceful shutdown
onstop!(app) do
    @info "Closing connections..."
    close_database!()
end

# Spawn a background task at startup
background!(app) do
    while true
        cleanup_expired_sessions!()
        sleep(60)
    end
end
```

---

## Cookies

```julia
route!(router, :get, "/profile", req -> begin
    session = get(cookies(req), "session", nothing)
    session === nothing && return text("Not logged in"; status=401)
    text("Hello!")
end)

route!(router, :post, "/login", req -> begin
    c = Cookie("session", "abc123";
        httponly = true,
        secure   = true,
        max_age  = 3600,
        samesite = :strict,
    )
    bake(text("Logged in"), c)
end)
```

---

## Security Headers

```julia
use!(app, security(
    hsts_max_age  = 31_536_000,          # 1 year HSTS
    frame_options = "DENY",              # X-Frame-Options
    csp           = "default-src 'self'",# Content-Security-Policy
))
```

Default headers: `Strict-Transport-Security`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'self'`, `Referrer-Policy: strict-origin-when-cross-origin`.

---

## Testing

Use the built-in `TestClient` for fast, network-free testing:

```julia
using Test, Mongoose

app = App(; router=Router())
route!(app.router, :get, "/hello", req -> json(Dict("msg" => "hi")))
use!(app, cors())

client = TestClient(app)

# Make requests without starting a server
resp = client(:get, "/hello")
@test resp.status == 200
@test contains(resp.body, "\"msg\"")

# Test with headers, body, query params
resp = client(:post, "/users";
    body = """{"name": "Alice"}""",
    headers = ["Content-Type" => "application/json"],
    query = Dict("notify" => "true"),
)
@test resp.status == 201
```

---

## Full Example

A complete production app with REST API, WebSocket, SSE, middleware, and DI:

```julia
using Mongoose

router = Router()

# Health
route!(router, :get, "/health", req -> text("ok"))

# REST API
route!(router, :get, "/api/users/:id::Int", (req, id) ->
    json(Dict("id" => id, "name" => "User $id"))
)

route!(router, :post, "/api/users", req -> begin
    data = body(req)
    json(Dict("created" => data["name"]); status=201)
end)

# WebSocket
ws!(router, "/ws";
    on_message = msg -> Message(Mongoose.encode(Json, Dict("ack" => true))),
    on_open = req -> @info("WS connected"),
    on_close = () -> @info("WS disconnected"),
)

# SSE
route!(router, :get, "/events", req ->
    sse(req) do writer
        for i in 1:5
            emit(writer; data="tick $i", event="heartbeat", id=string(i))
            sleep(1)
        end
    end
)

# App
app = App(; router=router, workers=4, request_timeout=10_000, ws_idle_timeout=60_000)

use!(app, security())
use!(app, health())
use!(app, metrics())
use!(app, cors(origins="*"))
use!(app, compress(min_size=1024))
use!(app, logger())
use!(app, bearer(t -> t == "secret"); paths=["/api"])

serve!(app, "public"; uri_prefix="/static")

onerror!(app, 500, json(Dict("error" => "Internal error"); status=500))

service!(app, :version, "1.0.0")

start!(app; port=8080)
```

---

## Deployment

- **Direct HTTPS**: Use `TLSConfig` for native TLS termination.
- **Reverse Proxy**: Place behind nginx/Caddy/Traefik for TLS + load balancing.
- **Docker**: Minimal base image — only needs the Julia runtime and compiled sysimage.
- **Kubernetes**: Built-in `/healthz`, `/readyz`, `/livez` endpoints via `health()` middleware.

---

## Documentation

Full API reference and examples: **[AbrJA.github.io/Mongoose.jl](https://AbrJA.github.io/Mongoose.jl/dev)**

## License

Distributed under the GPL-2 License. See [`LICENSE`](LICENSE) for details.
