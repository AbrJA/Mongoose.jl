# Mongoose.jl

**Mongoose.jl** is a lightweight, high-performance HTTP & WebSocket server for Julia, built on the [Mongoose C library](https://github.com/cesanta/mongoose).

**Key features:**
- Minimal dependencies — only `Mongoose_jll` and `PrecompileTools`
- Sub-100ms time-to-first-response via `PrecompileTools`
- Sync and async server modes with configurable worker pools
- Dynamic and static (AOT-compatible) routing with typed path parameters
- Built-in middleware: CORS, rate limiting, authentication, logging, static files
- WebSocket support on the same router
- JSON as an optional package extension (loads automatically with `JSON.jl`)
- Full compatibility with `juliac --trim=safe` for compiled binaries

## Installation

```julia
] add Mongoose
```

For JSON support:

```julia
] add JSON
```

## Quick Start

```julia
using Mongoose

router = Router()

route!(router, :get, "/", req -> Response(200, ContentType.text, "Hello!"))
route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, ContentType.text, "User $id"))

server = AsyncServer(router; workers=4)
start!(server, port=8080, blocking=false)

# When done
shutdown!(server)
```

## Architecture

Mongoose.jl uses a decoupled architecture: a **Router** defines the routes and handlers, while a **Server** manages networking, concurrency, and the event loop.

```
                ┌─────────────────────────────────┐
                │          Router                  │
                │  route!(:get, "/users/:id", h)   │
                │  ws!("/chat", on_message=h)      │
                └────────────┬────────────────────┘
                             │
                     ┌───────▼───────┐
                     │    Server     │
                     │  (event loop) │
                     └───┬───┬───┬──┘
                         │   │   │
                         ▼   ▼   ▼       (AsyncServer only)
                       Worker tasks
```

### Server Types

**`AsyncServer`** — Runs the event loop on a background task and dispatches requests to a pool of worker tasks via channels. Ideal for production APIs and applications where you want non-blocking operation.

```julia
server = AsyncServer(router;
    workers=4,              # Number of worker tasks
    nqueue=1024,            # Channel buffer size
    timeout=0,              # Poll timeout (ms)
    max_body_size=1048576,  # Max request body in bytes (default: 1MB)
    drain_timeout_ms=5000,  # Graceful shutdown drain timeout (ms)
    request_timeout_ms=0,   # Per-request timeout (0 = disabled)
    error_responses=Dict{Int,Response}()  # Custom responses by status code
)
```

**`SyncServer`** — Runs the event loop on the main thread (blocking). Suitable for simple scripts, or required for AOT compilation with `juliac --trim=safe`.

```julia
server = SyncServer(router;
    timeout=1,              # Poll timeout (ms), default: 1
    max_body_size=1048576,
    drain_timeout_ms=5000,
    error_responses=Dict{Int,Response}()
)
```

### ServerConfig

All constructor keyword arguments can be consolidated into a `ServerConfig` struct — useful for environment-driven configuration:

```julia
config = ServerConfig(
    workers            = parse(Int, get(ENV, "WORKERS", "4")),
    max_body_size      = parse(Int, get(ENV, "MAX_BODY", "1048576")),
    request_timeout_ms = parse(Int, get(ENV, "REQ_TIMEOUT_MS", "0")),
    drain_timeout_ms   = 10_000,
)

server = AsyncServer(router, config)  # or SyncServer(router, config)
```

| Field | Default | Description |
|-------|---------|-------------|
| `timeout` | `1` | Poll timeout in ms (`0` = min latency, high CPU) |
| `max_body_size` | 1 MB | Max request body in bytes |
| `drain_timeout_ms` | 5000 | Graceful-shutdown drain period in ms |
| `request_timeout_ms` | `0` | Per-request timeout in ms; `0` = disabled |
| `workers` | `4` | Worker tasks (`AsyncServer` only) |
| `nqueue` | `1024` | Channel buffer size (`AsyncServer` only) |
| `error_responses` | `Dict()` | Custom `Response` keyed by status code |

### Lifecycle

```julia
start!(server; host="127.0.0.1", port=8080, blocking=true)
shutdown!(server)  # Graceful: drains in-flight requests, stops workers, frees C resources
```

## Routing

### Dynamic Router

Routes are registered with `route!` using a method symbol (or string) and a path pattern:

```julia
router = Router()

# Symbol methods
route!(router, :get, "/hello", req -> Response(200, ContentType.text, "hi"))
route!(router, :post, "/data", req -> Response(200, ContentType.text, "ok"))
route!(router, :put, "/update", req -> Response(200, ContentType.text, "updated"))
route!(router, :patch, "/patch", req -> Response(200, ContentType.text, "patched"))
route!(router, :delete, "/remove", req -> Response(200, ContentType.text, "deleted"))

# Other HTTP methods
route!(router, :options, "/alt", req -> Response(200, ContentType.text, "ok"))
```

GET routes automatically respond to HEAD requests (body omitted).

### Path Parameters

Path segments prefixed with `:` are captured as parameters. Optional type annotations trigger automatic parsing:

```julia
# String parameter (default)
route!(router, :get, "/users/:name", (req, name) -> ...)

# Typed parameters
route!(router, :get, "/items/:id::Int", (req, id) -> ...)
route!(router, :get, "/price/:val::Float64", (req, val) -> ...)
```

### Convenience: Routes on Servers

Routes can be added directly on an already-created server:

```julia
server = AsyncServer(router)
route!(server, :get, "/health", req -> Response(200, ContentType.text, "ok"))
```

### Static Router (AOT)

The `@router` macro generates a compile-time dispatch function with zero dynamic allocation. This is required for `juliac --trim=safe`:

```julia
@router MyApi begin
    get("/", req -> Response(200, ContentType.text, "Hello"))
    get("/users/:id::Int", (req, id) -> Response(200, ContentType.text, "User $id"))
    post("/data", req -> Response(200, ContentType.text, "received"))
    ws("/chat", on_message = msg -> Message("Echo: $(msg.data)"))
end

server = SyncServer(MyApi())
start!(server, port=8080)
```

## Request & Response

### Request

Handlers receive a `Request`:

| Accessor | Returns | Description |
|----------|---------|-------------|
| `req.body` | `String` | Raw request body |
| `get(req.headers, "name", nothing)` | `String` or `nothing` | Case-insensitive header lookup |
| `req.query` | `String` | Full query string |
| `getcontext!(req)` | `Dict{Symbol,Any}` | Lazily-allocated context dict for middleware data |

### Response

Construct responses with a status code, headers, and body:

```julia
# Simple text response
Response(200, ContentType.text, "Hello!")

# Convenience: plain text with auto Content-Type
Response(200, "Hello!")
Response(404, "Not Found")

# JSON response
Response(200, ContentType.json, """{"ok": true}""")

# Binary body (e.g. image or file bytes)
Response(200, "Content-Type: image/png\r\n", read("image.png"))

# Binary format type
Response(Binary, read("data.bin"); status=200)
```

### ContentType

Pre-formatted Content-Type header strings:

| Field | MIME Type |
|-------|-----------|
| `ContentType.text` | `text/plain` |
| `ContentType.json` | `application/json` |
| `ContentType.html` | `text/html` |
| `ContentType.xml` | `application/xml` |
| `ContentType.css` | `text/css` |
| `ContentType.js` | `application/javascript` |


Headers can be concatenated: `ContentType.text * "X-Custom: value\r\n"`

### Query String Utilities

```julia
# Parse query string into a typed struct (not exported — call as Mongoose.query)
struct SearchQuery
    q::String
    page::Int
end

# From a raw string:
s = Mongoose.query(SearchQuery, "q=julia&page=1")  # SearchQuery("julia", 1)

# From a request:
route!(router, :get, "/search", req -> begin
    s = Mongoose.query(SearchQuery, req)
    Response(200, ContentType.text, "Searching: $(s.q) page $(s.page)")
end)
```

## WebSocket Support

Register WebSocket endpoints with `ws!`:

```julia
ws!(router, "/chat",
    on_message = (msg::Message) -> Message("Echo: $(msg.data)"),
    on_open    = (req::Request) -> println("connected: ", req.uri),
    on_close   = () -> println("disconnected")
)
```

- `on_message` receives a `Message` — `msg.data` is `String` (text frame) or `Vector{UInt8}` (binary frame)
- Return a `Message`, `String`, or `Vector{UInt8}` to send a reply; `nothing` for no reply
- `on_open` receives the HTTP upgrade `Request` (headers, URI, etc.); `on_close` takes no arguments
- Both `on_open` and `on_close` are optional

## Middleware

Middleware is added with `use!` and executes in registration order. Each middleware can short-circuit the request (e.g., return a 401) or pass through to the next handler.

### Path-Scoped Middleware

Apply middleware only to specific path prefixes:

```julia
use!(server, bearer_token(t -> t == "secret"); paths=["/api", "/admin"])
use!(server, rate_limit(max_requests=10); paths=["/api/expensive"])
```

Requests to other paths bypass the middleware entirely.

### Logger

Logs method, URI, status code, and duration for each request.

```julia
use!(server, logger())                         # Log all requests to stderr
use!(server, logger(threshold_ms=50))           # Only log requests slower than 50ms
use!(server, logger(output=open("log.txt","a"))) # Custom output
use!(server, logger(structured=true))           # JSON log lines
```

Structured mode emits one JSON object per line:
```json
{"method":"GET","uri":"/users/1","status":200,"duration_ms":1.23,"ts":"2025-01-15T10:30:00"}
```

### CORS

Handles `OPTIONS` preflight and adds CORS headers to all responses.

```julia
use!(server, cors())                                        # Allow all origins
use!(server, cors(origins="https://example.com"))            # Specific origin
use!(server, cors(methods="GET, POST", headers="Authorization", max_age=3600))
```

### Rate Limiting

Fixed-window rate limiter keyed by client IP address.

```julia
use!(server, rate_limit())                                  # 100 req / 60s (defaults)
use!(server, rate_limit(max_requests=10, window_seconds=30)) # Stricter limits
```

Returns `429 Too Many Requests` with a `Retry-After` header when exceeded.

### Authentication

**Bearer token:**

```julia
use!(server, bearer_token(token -> token == "secret-123"))
```

Returns `401` with `WWW-Authenticate: Bearer` if missing or invalid scheme, `403` if the validator returns `false`.

**API key:**

```julia
use!(server, api_key(header_name="X-API-Key", keys=Set(["key1", "key2"])))
```

Returns `401` if the header is missing or the key is not in the allowed set.

### Prometheus Metrics

The `metrics()` middleware tracks request counts and latency histograms and exposes a Prometheus scrape endpoint:

```julia
use!(server, metrics())          # exposes GET /metrics
use!(server, metrics(path="/internal/metrics"))  # custom path
```

Metrics exposed:

| Metric | Type | Labels |
|--------|------|--------|
| `http_requests_total` | counter | `method`, `status` |
| `http_request_duration_seconds` | histogram | `le` (11 buckets: 5ms–10s) |

### Static Files

Serve a directory of static assets using the C-level file server (supports Range, ETag, Last-Modified, and gzip):

```julia
serve_dir!(server, "public")
```

Serves `index.html` for directory requests. Returns `404` for missing files. Path traversal is blocked at the C level.

## Error Handling

### Custom Error Responses

Register custom `Response` objects for specific HTTP status codes. The following codes are customizable: `500` (unhandled exception), `413` (body too large), `504` (request timeout).

```julia
using Mongoose, JSON

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

server = AsyncServer(router)

# Custom JSON 500 response
error_response!(server, 500, Response(Json, Dict("error" => "Internal server error"); status=500))

# Custom 413 response
error_response!(server, 413, Response(500, ContentType.json, """{"error":"Request body too large"}"""))
```

You can also pass a pre-built dict at construction time:

```julia
errors = Dict{Int,Response}(
    500 => Response(500, ContentType.json, """{"error":"Internal error"}"""),
    413 => Response(413, ContentType.json, """{"error":"Body too large"}"""),
)
server = SyncServer(router; error_responses=errors)
```

### Custom 404 Pages

For a custom 404 response, add a wildcard catch-all route — no special API needed:

```julia
route!(router, :get, "*", req -> Response(404, ContentType.html, read("404.html", String)))
```

### Request Timeout

Set a per-request timeout (in milliseconds) to prevent slow handlers from blocking the server:

```julia
server = AsyncServer(router; request_timeout_ms=5000)
```

When a request exceeds the timeout, the server returns `504 Gateway Timeout`.

### Request ID

Every request is automatically assigned a unique monotonic ID, injected as an `X-Request-Id` response header. This is useful for correlating logs and debugging:

```
HTTP/1.1 200 OK
X-Request-Id: 42
Content-Type: text/plain
```

## JSON

JSON support requires `JSON.jl`. Extend `render_body` once at startup to enable `Response(Json, ...)` throughout your app:

```julia
using Mongoose, JSON

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

route!(router, :post, "/api", req -> begin
    # Parse body manually
    data = JSON.parse(req.body)

    # Send JSON response (auto Content-Type)
    Response(Json, Dict("ok" => true); status=201)
end)
```

## Examples

More comprehensive examples are available on the [Examples](examples.md) page.

## API Reference

The full API documentation is available on the [API](api.md) page.

## License

Distributed under the GPL-2 License.
