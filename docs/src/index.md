# Mongoose.jl

**Mongoose.jl** is a lightweight, high-performance HTTP & WebSocket server for Julia, built on the [Mongoose C library](https://github.com/cesanta/mongoose).

**Key features:**
- Minimal dependencies — only `Mongoose_jll` and `PrecompileTools`
- Sub-100ms time-to-first-response via `PrecompileTools`
- Sync and async server modes with configurable worker pools
- Dynamic and static (AOT-compatible) routing with typed path parameters
- Automatic HEAD responses from GET handlers; typed param mismatch returns 404
- Built-in middleware: CORS, rate limiting, authentication, logging, static files
- WebSocket support on the same router — with upgrade rejection, frame limits, and idle timeout
- 503 backpressure when the worker queue is full or too many concurrent timed tasks
- Optional JSON integration via `JSON.jl` with explicit setup by the user
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

route!(router, :get, "/", req -> Response(Plain, "Hello!"))
route!(router, :get, "/users/:id::Int", (req, id) -> Response(Plain, "User $id"))

server = Async(router; nworkers=4)
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
                         ▼   ▼   ▼       (Async only)
                       Worker tasks
```

### Server Types

**`Async`** — Runs the event loop on a background task and dispatches requests to a pool of worker tasks via channels. Ideal for production APIs and applications where you want non-blocking operation.

```julia
server = Async(router;
    nworkers=4,                  # Number of worker tasks
    nqueue=1024,                 # Channel buffer size
    poll_timeout=0,              # Poll timeout (ms)
    max_body=1048576,            # Max request/WS-frame body in bytes (default: 1 MB)
    drain_timeout=5000,          # Graceful shutdown drain timeout (ms)
    request_timeout=0,           # Per-request timeout (0 = disabled)
    ws_idle_timeout=0,         # WebSocket idle timeout in seconds (0 = disabled)
    errors=Dict{Int,Response}()  # Custom responses by status code
)
```

**`Server`** — Runs the event loop on the main thread (blocking). Suitable for simple scripts, or required for AOT compilation with `juliac --trim=safe`.

```julia
server = Server(router;
    poll_timeout=1,              # Poll timeout (ms), default: 1
    max_body=1048576,
    drain_timeout=5000,
    errors=Dict{Int,Response}()
)
```

### Config

All constructor keyword arguments can be consolidated into a `Config` struct — useful for environment-driven configuration:

```julia
config = Config(
    nworkers        = parse(Int, get(ENV, "WORKERS", "4")),
    max_body        = parse(Int, get(ENV, "MAX_BODY", "1048576")),
    request_timeout = parse(Int, get(ENV, "REQ_TIMEOUT", "0")),
    ws_idle_timeout = 60,
    drain_timeout   = 10_000,
)

server = Async(router, config)  # or Server(router, config)
```

| Field | Default | Description |
|-------|---------|-------------|
| `poll_timeout` | `1` | Poll timeout in ms (`0` = min latency, high CPU) |
| `max_body` | 1 MB | Max request body in bytes; also the WebSocket frame size limit |
| `drain_timeout` | 5000 | Graceful-shutdown drain period in ms |
| `request_timeout` | `0` | Per-request timeout in ms; `0` = disabled |
| `ws_idle_timeout` | `0` | WebSocket idle timeout in seconds; `0` = disabled |
| `nworkers` | `4` | Worker tasks (`Async` only) |
| `nqueue` | `1024` | Channel buffer size (`Async` only) |
| `errors` | `Dict()` | Custom `Response` keyed by status code |

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
route!(router, :get, "/hello", req -> Response(Plain, "hi"))
route!(router, :post, "/data", req -> Response(Plain, "ok"))
route!(router, :put, "/update", req -> Response(Plain, "updated"))
route!(router, :patch, "/patch", req -> Response(Plain, "patched"))
route!(router, :delete, "/remove", req -> Response(Plain, "deleted"))

# Other HTTP methods
route!(router, :options, "/alt", req -> Response(Plain, "ok"))
```

GET routes automatically respond to HEAD requests (body omitted).

### Path Parameters

Path segments prefixed with `:` are captured as parameters. Optional type annotations trigger automatic parsing:

```julia
# String parameter (default)
route!(router, :get, "/users/:name", (req, name) -> ...)

# Typed parameters — invalid values return 404 (not 500)
route!(router, :get, "/items/:id::Int", (req, id) -> ...)    # /items/abc → 404
route!(router, :get, "/price/:val::Float64", (req, val) -> ...)
```

### Convenience: Routes on Servers

Routes can be added directly on an already-created server:

```julia
server = Async(router)
route!(server, :get, "/health", req -> Response(Plain, "ok"))
```

### Static Router (AOT)

The `@router` macro generates a compile-time dispatch function with zero dynamic allocation. This is required for `juliac --trim=safe`:

```julia
@router MyApi begin
    get("/", req -> Response(Plain, "Hello"))
    get("/users/:id::Int", (req, id) -> Response(Plain, "User $id"))
    post("/data", req -> Response(Plain, "received"))
    ws("/chat", on_message = msg -> Message("Echo: $(msg.data)"))
end

server = Server(MyApi())
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
| `context!(req)` | `Dict{Symbol,Any}` | Lazily-allocated context dict for middleware data |

### Response

Construct responses with a format type, body, and optional keyword arguments:

```julia
# Format type sets Content-Type automatically
Response(Plain, "Hello!")                    # text/plain, status 200
Response(Json, """{"ok": true}""")          # application/json, status 200
Response(Html, "<p>hi</p>")                 # text/html, status 200
Response(Json, body; status=201)            # custom status
Response(Html, body; status=404)            # custom status
Response(Json, body; headers=["X-Custom" => "value"])  # extra headers

# Binary body (e.g., image or file bytes)
Response(Binary, read("image.png"); status=200)

# Raw form (when you already have a pre-formatted headers string)
Response(200, "Content-Type: image/png\r\n", read("image.png"))
```

The format type determines the `Content-Type` header:

| Format | Content-Type |
|--------|-------------|
| `Plain`   | `text/plain; charset=utf-8` |
| `Html`   | `text/html; charset=utf-8` |
| `Json`   | `application/json; charset=utf-8` |
| `Xml`    | `application/xml; charset=utf-8` |
| `Css`    | `text/css; charset=utf-8` |
| `Js`     | `application/javascript; charset=utf-8` |
| `Binary` | `application/octet-stream` |

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
    Response(Plain, "Searching: $(s.q) page $(s.page)")
end)
```

## WebSocket Support

Register WebSocket endpoints with `ws!`:

```julia
ws!(router, "/chat",
    on_message = (msg::Message) -> Message("Echo: $(msg.data)"),
    on_open    = (req::Request) -> begin
        # Return false to reject the upgrade — sends 403 to the client
        auth = get(req.headers, "authorization", nothing)
        auth === nothing && return false
        @info "WS connected" uri=req.uri
    end,
    on_close   = () -> println("disconnected")
)
```

| Callback | Signature | Notes |
|----------|-----------|-------|
| `on_open` | `(req::Request) → Any` | Called before upgrade. Return `false` to reject (sends 403). Optional. |
| `on_message` | `(msg::Message) → Message \| String \| Vector{UInt8} \| nothing` | Called per frame. Return `nothing` for no reply. |
| `on_close` | `() → Any` | Called after close. Connection already gone — no arguments. Optional. |

**Production features:**
- **Frame size limit** — WebSocket frames are subject to the same `max_body` limit as HTTP requests. Oversized frames close the connection.
- **Idle timeout** — set `ws_idle_timeout` (seconds) on the server to auto-close connections that send no frames within the window. Connections are checked every 5 seconds.
- **Upgrade rejection** — return `false` from `on_open` to refuse the WebSocket upgrade. The client receives `403 Forbidden` and no WebSocket connection is established.
- **Ping/pong** — RFC 6455 control frames are handled automatically.

## Middleware

Middleware is added with `plug!` and executes in registration order. Each middleware can short-circuit the request (e.g., return a 401) or pass through to the next handler.

### Path-Scoped Middleware

Apply middleware only to specific path prefixes:

```julia
plug!(server, bearer(t -> t == "secret"); paths=["/api", "/admin"])
plug!(server, ratelimit(max_requests=10); paths=["/api/expensive"])
```

Requests to other paths bypass the middleware entirely.

### Logger

Logs method, URI, status code, and duration for each request.

```julia
plug!(server, logger())                         # Log all requests to stderr
plug!(server, logger(threshold=50))           # Only log requests slower than 50ms
plug!(server, logger(output=open("log.txt","a"))) # Custom output
plug!(server, logger(structured=true))           # JSON log lines
```

Structured mode emits one JSON object per line:
```json
{"method":"GET","uri":"/users/1","status":200,"duration":1.23,"ts":"2025-01-15T10:30:00"}
```

### CORS

Handles `OPTIONS` preflight and adds CORS headers to all responses.

```julia
plug!(server, cors())                                        # Allow all origins
plug!(server, cors(origins="https://example.com"))            # Specific origin
plug!(server, cors(methods="GET, POST", headers="Authorization", max_age=3600))
```

### Rate Limiting

Fixed-window rate limiter keyed by client IP address.

```julia
plug!(server, ratelimit())                                  # 100 req / 60s (defaults)
plug!(server, ratelimit(max_requests=10, window_seconds=30)) # Stricter limits
```

Returns `429 Too Many Requests` with a `Retry-After` header when exceeded.

### Authentication

**Bearer token:**

```julia
plug!(server, bearer(token -> token == "secret-123"))
```

Returns `401` with `WWW-Authenticate: Bearer` if missing or invalid scheme, `403` if the validator returns `false`.

**API key:**

```julia
plug!(server, apikey(header_name="X-API-Key", keys=Set(["key1", "key2"])))
```

Returns `401` if the header is missing or the key is not in the allowed set.

### Prometheus Metrics

The `metrics()` middleware tracks request counts and latency histograms and exposes a Prometheus scrape endpoint:

```julia
plug!(server, metrics())          # exposes GET /metrics
plug!(server, metrics(path="/internal/metrics"))  # custom path
```

Metrics exposed:

| Metric | Type | Labels |
|--------|------|--------|
| `http_requests_total` | counter | `method`, `status` |
| `http_request_duration_seconds` | histogram | `le` (11 buckets: 5ms–10s) |

### Static Files

Serve a directory of static assets using the C-level file server (supports Range, ETag, Last-Modified, and gzip):

```julia
mount!(server, "public")
```

Serves `index.html` for directory requests. Returns `404` for missing files. Path traversal is blocked at the C level.

## Error Handling

### Custom Error Responses

Register custom `Response` objects for specific HTTP status codes. The following codes are customizable: `500` (unhandled exception), `413` (body too large), `503` (worker queue full / server overloaded), `504` (request timeout).

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

router = Router()
server = Async(router)

# Custom JSON 500 response
fail!(server, 500, Response(Json, Dict("error" => "Internal server error"); status=500))

# Custom 413 response
fail!(server, 413, Response(Json, """{"error":"Request body too large"}"""; status=413))

# Custom 503 response — returned when the worker channel is full or too many
# concurrent timed tasks are in-flight (server overloaded)
fail!(server, 503, Response(Json, """{"error":"Service temporarily unavailable"}"""; status=503))
```

You can also pass a pre-built dict at construction time:

```julia
router = Router()
errors = Dict{Int,Response}(
    500 => Response(Json, """{"error":"Internal error"}"""; status=500),
    413 => Response(Json, """{"error":"Body too large"}"""; status=413),
    503 => Response(Json, """{"error":"Service unavailable"}"""; status=503),
)
server = Server(router; errors=errors)
```

### Custom 404 Pages

For a custom 404 response, add a wildcard catch-all route — no special API needed:

```julia
route!(router, :get, "*", req -> Response(Html, read("404.html", String); status=404))
```

### Request Timeout

Set a per-request timeout (in milliseconds) to prevent slow handlers from blocking the server:

```julia
server = Async(router; request_timeout=5000)
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

JSON support requires `JSON.jl`. Extend `encode` once at startup to enable `Response(Json, ...)` throughout your app:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

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
