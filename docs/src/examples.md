# Examples

## Hello World

The simplest possible Mongoose.jl server:

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> Response(Plain, "Hello, World!"))

server = Server(router)
start!(server, port=8080)
```

## REST API with Path Parameters

Dynamic path segments are captured with `:name` syntax. Add type annotations for automatic parsing:

```julia
using Mongoose

router = Router()

# String parameter (default)
route!(router, :get, "/greet/:name", (req, name) -> begin
    Response(Plain, "Hello, $(name)!")
end)

# Typed integer parameter — invalid value (e.g. /users/abc) returns 404
route!(router, :get, "/users/:id::Int", (req, id) -> begin
    Response(Json, """{"id": $id, "type": "$(typeof(id))"}""")  
end)

# Float parameter
route!(router, :get, "/price/:amount::Float64", (req, amount) -> begin
    tax = amount * 0.16
    Response(Json, """{"amount": $amount, "tax": $tax}""")
end)

server = Async(router)
start!(server, port=8080, blocking=false)
```

## Query Parameters

`req.query` is a `Dict{String,String}` of the parsed query parameters. Use `get` to read values with defaults:

```julia
using Mongoose

router = Router()

route!(router, :get, "/search", req -> begin
    q    = get(req.query, "q", "")
    page = something(tryparse(Int, get(req.query, "page", "1")), 1)
    isempty(q) && return Response(Plain, "Missing ?q= parameter"; status=400)
    Response(Json, "{\"query\": \"$q\", \"page\": $page}")
end)

server = Async(router)
start!(server, port=8080, blocking=false)
```

## JSON Request and Response

JSON support requires `JSON.jl`. Extend `encode` once at the top of your app to enable `Response(Json, ...)` with automatic Content-Type.

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

struct UserProfile
    username::String
    age::Int
    active::Bool
end

router = Router()

# Return a JSON response
route!(router, :get, "/user/info", req -> begin
    Response(Json, Dict("username" => "Alice", "active" => true))
end)

# Parse JSON from request body
route!(router, :post, "/user/create", req -> begin
    data = JSON.parse(req.body)
    name = get(data, "username", "Guest")
    Response(Json, Dict("message" => "Hello, $name"); status=201)
end)

server = Async(router)
start!(server, port=8080, blocking=false)
```

## Parse Query Parameters

For structured access, read each key from `req.query` with `get` and parse types manually:

```julia
using Mongoose

router = Router()

route!(router, :get, "/search", req -> begin
    q     = get(req.query, "q", "")
    page  = something(tryparse(Int,  get(req.query, "page",  "1")), 1)
    limit = tryparse(Int, get(req.query, "limit", ""))
    Response(Plain, "Searching '$q' page $page")
end)

server = Async(router)
start!(server, port=8080, blocking=false)
```

## WebSocket Echo Server

Register WebSocket endpoints with `ws!`. The `on_message` handler receives a `Message` whose `.data` field is either `String` (text frame) or `Vector{UInt8}` (binary frame).

```julia
using Mongoose

router = Router()

ws!(router, "/echo",
    on_message = (msg::Message) -> begin
        if msg.data isa String
            return Message("Echo: $(msg.data)")
        else
            return Message(msg.data)  # Echo binary data back
        end
    end,
    on_open  = (req::Request) -> println("Client connected from ", req.uri),
    on_close = () -> println("Client disconnected")
)

server = Async(router)
start!(server, port=8080, blocking=false)
```

## WebSocket Upgrade Rejection

Return `false` from `on_open` to reject the upgrade. The client receives `403 Forbidden` and no WebSocket connection is established.

```julia
using Mongoose

router = Router()

ws!(router, "/secure",
    on_message = (msg::Message) -> Message("Hello, authenticated user!"),
    on_open    = (req::Request) -> begin
        token = get(req.headers, "authorization", nothing)
        # Reject if no token or wrong token
        if token === nothing || token != "Bearer secret"
            return false  # → client gets 403 Forbidden
        end
        @info "WS authenticated" uri=req.uri
    end,
    on_close   = () -> @info "WS disconnected"
)

server = Async(router)
start!(server, port=8080, blocking=false)
```

## Middleware Stack

Middleware executes in registration order. Each middleware can inspect the request, short-circuit with a response, or pass through to the next handler.

```julia
using Mongoose

router = Router()
route!(router, :get, "/api/data", req -> begin
    Response(Json, """{"status": "ok"}""")
end)

server = Async(router)

# 1. Log all requests (method, URI, status, duration in ms)
plug!(server, logger())

# 2. CORS headers + OPTIONS preflight handling
plug!(server, cors(origins="https://example.com"))

# 3. Rate limiting: 100 requests per 60 seconds per client IP
plug!(server, ratelimit(max_requests=100, window_seconds=60))

# 4. Bearer token authentication
plug!(server, bearer(token -> token == "my-secret-token"))

start!(server, port=8080, blocking=false)
```

## API Key Authentication

Protect endpoints with an API key header check:

```julia
using Mongoose

router = Router()
route!(router, :get, "/internal", req -> Response(Plain, "Internal data"))

server = Async(router)
plug!(server, apikey(header_name="X-API-Key", keys=Set(["key-abc", "key-xyz"])))

start!(server, port=8080, blocking=false)
```

## Logger with Threshold

Only log requests that exceed a duration threshold — useful for identifying slow endpoints:

```julia
using Mongoose

router = Router()
route!(router, :get, "/fast", req -> Response(Plain, "fast"))
route!(router, :get, "/slow", req -> begin
    sleep(0.1)
    Response(Plain, "slow")
end)

server = Async(router)

# Only log requests taking longer than 50ms
plug!(server, logger(threshold=50))

start!(server, port=8080, blocking=false)
```

## Serving Static Files

Serve a directory of HTML, CSS, JS, and other assets using the C-level file server
(supports Range, ETag, Last-Modified, and gzip):

```julia
using Mongoose

server = Async(Router())

# Serve files from "public/" directory
# GET /style.css  →  public/style.css
# GET /            →  public/index.html
mount!(server, "public")

start!(server, port=8080, blocking=false)
```

## Request Context

Middleware can attach data to the request context via `context!`, which handlers can access:

```julia
using Mongoose

struct UserLookup <: Mongoose.AbstractMiddleware
    db::Dict{String, String}
end

function (mw::UserLookup)(request, params, next)
    token = get(request.headers, "authorization", nothing)
    if token !== nothing
        user = get(mw.db, replace(token, "Bearer " => ""), nothing)
        if user !== nothing
            context!(request)[:user] = user
        end
    end
    return next()
end

router = Router()
route!(router, :get, "/me", req -> begin
    user = get(context!(req), :user, "anonymous")
    Response(Plain, "Hello, $user!")
end)

server = Async(router)
plug!(server, UserLookup(Dict("token-123" => "Alice", "token-456" => "Bob")))

start!(server, port=8080, blocking=false)
```

## Async Server with Multiple Workers

For higher throughput, start Julia with multiple threads and configure the worker count:

```julia
using Mongoose

router = Router()

route!(router, :get, "/compute", req -> begin
    result = sum(rand(1_000_000))
    Response(Plain, "Computed: $result")
end)

# 8 worker tasks processing requests concurrently
server = Async(router; nworkers=8)
start!(server, port=8080, blocking=false)
```

Start Julia with threads: `julia -t 8`

## Static Router (AOT Compilation)

For ahead-of-time compiled binaries with `juliac --trim=safe`, use the `@router` macro instead of `Router()`:

```julia
using Mongoose

@router MyApi begin
    get("/", req -> Response(Plain, "Hello from AOT!"))
    get("/users/:id::Int", (req, id) -> Response(Plain, "User $id"))
    post("/echo", req -> Response(Plain, req.body))
    ws("/chat", on_message = msg -> Message("Echo: $(msg.data)"))
end

server = Server(MyApi())
start!(server, port=8080)
```

This generates zero-allocation dispatch at compile time — no `Dict` lookups, no dynamic dispatch.

## Full Application Example

A complete example combining multiple features:

```julia
using Mongoose, JSON

struct CreateUser
    name::String
    email::String
end

router = Router()

# Health check
route!(router, :get, "/health", req -> Response(Plain, "ok"))

# JSON API
route!(router, :get, "/api/users/:id::Int", (req, id) -> begin
    Response(Json, Dict("id" => id, "name" => "User $id"))
end)

route!(router, :post, "/api/users", req -> begin
    data = JSON.parse(req.body)
    name = get(data, "name", "")
    Response(Json, Dict("created" => name); status=201)
end)

# WebSocket with idle timeout
ws!(router, "/ws/notifications",
    on_message = (msg::Message) -> Message("""{"ack": true}"""),
    on_open    = (req::Request) -> @info "WS client connected"
)

# Server with full middleware stack
# ws_idle_timeout: close WS connections that are idle for more than 60 seconds
server = Async(router; nworkers=4, ws_idle_timeout=60)
plug!(server, logger(threshold=100))
plug!(server, cors(origins="https://myapp.com"))
plug!(server, ratelimit(max_requests=200, window_seconds=60))
mount!(server, "public")

start!(server, port=8080, blocking=false)
```

## Custom Error Responses

Register pre-built `Response` objects for specific HTTP status codes:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

router = Router()

route!(router, :get, "/fail", req -> error("Something broke"))
route!(router, :get, "/ok", req -> Response(200, "All good"))

# Custom 404: use a wildcard route
route!(router, :get, "*", req -> Response(Html, "<h1>Not Found</h1>"; status=404))

server = Async(router; request_timeout=5000)

fail!(server, 500, Response(Json, Dict("error" => "Internal error"); status=500))
fail!(server, 413, Response(Json, """{"error":"Body too large"}"""; status=413))
fail!(server, 503, Response(Json, """{"error":"Service temporarily unavailable"}"""; status=503))
fail!(server, 504, Response(Json, """{"error":"Request timed out"}"""; status=504))

start!(server, port=8080, blocking=false)
```

## Path-Scoped Middleware

Apply middleware only to specific URL prefixes:

```julia
using Mongoose

router = Router()

route!(router, :get, "/", req -> Response(200, "Welcome"))
route!(router, :get, "/api/users", req -> Response(200, "User list"))
route!(router, :get, "/admin/dashboard", req -> Response(200, "Dashboard"))

server = Async(router)

# Auth only for /api and /admin routes
plug!(server, bearer(t -> t == "secret"); paths=["/api", "/admin"])

# Rate limit only expensive API endpoints
plug!(server, ratelimit(max_requests=10, window_seconds=60); paths=["/api"])

# Logger for everything
plug!(server, logger(structured=true))

start!(server, port=8080, blocking=false)
```

## Structured JSON Logging

Emit structured JSON log lines for machine-parsable logging:

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> Response(200, "ok"))

server = Async(router)
plug!(server, logger(structured=true, output=open("access.log", "a")))

start!(server, port=8080, blocking=false)
```

Each log line is a JSON object:
```json
{"method":"GET","uri":"/","status":200,"duration":0.42,"ts":"2025-01-15T10:30:00"}
```

## Prometheus Metrics

Expose Prometheus-compatible metrics with the `metrics()` middleware. It automatically tracks request counts and latency histograms, and serves them at `GET /metrics`:

```julia
using Mongoose

router = Router()
route!(router, :get, "/api/data", req -> Response(Json, """{"ok":true}"""))

server = Async(router; nworkers=4)
plug!(server, health())
plug!(server, metrics())          # serves GET /metrics

start!(server; host="0.0.0.0", port=8080)
```

Sample output at `GET /metrics`:
```
# HELP http_requests_total Total number of HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200"} 42

# HELP http_request_duration_seconds HTTP request latency in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005"} 38
http_request_duration_seconds_bucket{le="0.01"} 41
...
http_request_duration_seconds_bucket{le="+Inf"} 42
http_request_duration_seconds_sum 0.127
http_request_duration_seconds_count 42
```

Prometheus `scrape_configs`:
```yaml
scrape_configs:
  - job_name: myapp
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: /metrics
```

## Binary Responses

Use the `Binary` format for raw byte responses:

```julia
using Mongoose

router = Router()

route!(router, :get, "/image", req -> begin
    data = read("logo.png")
    Response(Binary, data; status=200)
end)

server = Async(router)
start!(server, port=8080, blocking=false)
```

## Production Deployment

### Environment-Driven Configuration

Read server settings from environment variables with sensible defaults:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

# --- Configuration from environment ---
const HOST    = get(ENV, "HOST", "0.0.0.0")
const PORT    = parse(Int, get(ENV, "PORT", "8080"))
const WORKERS = parse(Int, get(ENV, "WORKERS", string(Threads.nthreads())))
const MAX_BODY  = parse(Int, get(ENV, "MAX_BODY", "5242880"))  # 5 MB
const REQ_TIMEOUT = parse(Int, get(ENV, "request_timeout", "30000"))  # 30s
const LOG_LEVEL = get(ENV, "LOG_LEVEL", "info")

router = Router()

route!(router, :get, "/api/status", req -> Response(Json, Dict(
    "status" => "ok",
    "workers" => WORKERS,
    "julia_version" => string(VERSION)
)))

server = Async(router;
    nworkers=WORKERS,
    max_body=MAX_BODY,
    request_timeout=REQ_TIMEOUT,
    ws_idle_timeout=60,
    drain_timeout=10_000
)

# Middleware stack
plug!(server, health())
plug!(server, logger(structured=(LOG_LEVEL == "debug")))
plug!(server, cors())

start!(server; host=HOST, port=PORT)
```

Launch with: `HOST=0.0.0.0 PORT=3000 WORKERS=8 julia -t 8 --project server.jl`

### Graceful Shutdown with Signal Handling

Handle shutdown signals for clean container stops:

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> Response(200, "Running"))

server = Async(router; nworkers=4, drain_timeout=10_000)
plug!(server, health())

start!(server; host="0.0.0.0", port=8080, blocking=false)

# Block main thread and handle signals
try
    @info "Server ready. Press Ctrl+C to stop."
    while server.core.running[]
        sleep(1)
    end
catch e
    if e isa InterruptException
        @info "Received shutdown signal"
    else
        @error "Unexpected error" exception=(e, catch_backtrace())
    end
finally
    shutdown!(server)
end
```

### Multi-Service API with Route Groups

Organize a larger API using separate routers merged into one server:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

# --- User service ---
function register_user_routes!(router)
    route!(router, :get, "/api/v1/users", req -> begin
        Response(Json, [Dict("id" => 1, "name" => "Alice"), Dict("id" => 2, "name" => "Bob")])
    end)

    route!(router, :get, "/api/v1/users/:id::Int", (req, id) -> begin
        Response(Json, Dict("id" => id, "name" => "User $id"))
    end)

    route!(router, :post, "/api/v1/users", req -> begin
        data = JSON.parse(req.body)
        Response(Json, Dict("id" => 3, "name" => get(data, "name", "")); status=201)
    end)

    route!(router, :delete, "/api/v1/users/:id::Int", (req, id) -> begin
        Response(204, "", "")
    end)
end

function register_product_routes!(router)
    route!(router, :get, "/api/v1/products", req -> begin
        limit = tryparse(Int, get(req.query, "limit", ""))
        n = something(limit, 10)
        items = [Dict("id" => i, "name" => "Product $i", "price" => i * 9.99) for i in 1:n]
        Response(Json, items)
    end)

    route!(router, :get, "/api/v1/products/:id::Int", (req, id) -> begin
        Response(Json, Dict("id" => id, "name" => "Product $id", "price" => id * 9.99))
    end)
end

# --- Assemble ---
router = Router()
register_user_routes!(router)
register_product_routes!(router)

# Catch-all 404
route!(router, :get, "*", req -> Response(Json, Dict("error" => "Not found"); status=404))

server = Async(router; nworkers=4, request_timeout=15_000)

# Public: health + CORS on everything
plug!(server, health())
plug!(server, cors())
plug!(server, logger(structured=true))

# Auth only on API routes
plug!(server, bearer(t -> t == ENV["API_TOKEN"]); paths=["/api"])

# Rate limit per-client
plug!(server, ratelimit(max_requests=200, window_seconds=60); paths=["/api"])

start!(server; host="0.0.0.0", port=8080)
```

### Request Context for Auth Pipelines

Use middleware to inject authenticated user data into the request context:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

# --- Auth middleware that populates context ---
struct JWTAuth <: Mongoose.AbstractMiddleware
    secret::String
end

function (mw::JWTAuth)(request, params, next)
    token = get(request.headers, "authorization", nothing)
    token === nothing && return Response(Json, """{"error":"Missing token"}"""; status=401)

    # Strip "Bearer " prefix
    if length(token) > 7 && lowercase(token[1:7]) == "bearer "
        token = token[8:end]
    else
        return Response(Json, """{"error":"Invalid scheme"}"""; status=401)
    end

    # In production, decode and verify a real JWT here
    # For this example, we simulate user lookup
    ctx = context!(request)
    ctx[:user_id] = 42
    ctx[:role] = "admin"
    ctx[:token] = token

    return next()
end

# --- Role-based access control middleware ---
struct RequireRole <: Mongoose.AbstractMiddleware
    roles::Set{String}
end

function (mw::RequireRole)(request, params, next)
    ctx = context!(request)
    role = get(ctx, :role, "")
    if role ∉ mw.roles
        return Response(Json, """{"error":"Insufficient permissions"}"""; status=403)
    end
    return next()
end

router = Router()

route!(router, :get, "/api/profile", req -> begin
    ctx = context!(req)
    Response(Json, Dict("user_id" => ctx[:user_id], "role" => ctx[:role]))
end)

route!(router, :delete, "/api/admin/users/:id::Int", (req, id) -> begin
    Response(Json, Dict("deleted" => id))
end)

server = Async(router; nworkers=4)

# Apply auth to all /api routes
plug!(server, JWTAuth("my-secret"); paths=["/api"])

# Require admin role for /api/admin routes
plug!(server, RequireRole(Set(["admin"])); paths=["/api/admin"])

start!(server; port=8080, blocking=false)
```

### Kubernetes-Ready Health Checks

Configure health checks that integrate with your infrastructure:

```julia
using Mongoose

# Simulate external dependency checks
const DB_CONNECTED = Ref(true)
const CACHE_READY = Ref(true)

router = Router()
route!(router, :get, "/api/data", req -> Response(Json, """{"ok":true}"""))

server = Async(router; nworkers=4)

plug!(server, health(
    # Health check: all dependencies must be working
    health_check = () -> DB_CONNECTED[] && CACHE_READY[],

    # Readiness: is the service ready to accept traffic?
    # Return false during startup or when draining
    ready_check = () -> DB_CONNECTED[],

    # Liveness: is the process responsive?
    # Only return false if the process is deadlocked
    live_check = () -> true
))

plug!(server, logger(structured=true))

start!(server; host="0.0.0.0", port=8080)
```

Kubernetes probes configuration:
```yaml
livenessProbe:
  httpGet:
    path: /livez
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
  initialDelaySeconds: 3
  periodSeconds: 5
```

### File Upload with Size Validation

Handle file uploads with proper size limits and content type checking:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

router = Router()

route!(router, :post, "/api/upload", req -> begin
    ct = get(req.headers, "content-type", "")

    if !startswith(ct, "application/json")
        return Response(Json, """{"error":"Unsupported media type"}"""; status=415)
    end

    data = JSON.parse(req.body)
    filename = get(data, "filename", "")
    isempty(filename) && return Response(Json, """{"error":"Missing filename"}"""; status=400)

    Response(Json, Dict(
        "status" => "uploaded",
        "filename" => filename,
        "size" => length(req.body)
    ); status=201)
end)

# 10MB body limit for upload endpoint
server = Async(router; nworkers=4, max_body=10_485_760)

plug!(server, logger())
plug!(server, ratelimit(max_requests=30, window_seconds=60); paths=["/api/upload"])

start!(server; port=8080, blocking=false)
```

### WebSocket Chat Room

A multi-client chat server using WebSocket:

```julia
using Mongoose

router = Router()

route!(router, :get, "/", req -> Response(Html, """
    <html><body>
    <h1>Chat</h1>
    <div id="messages"></div>
    <input id="msg" type="text" /><button onclick="send()">Send</button>
    <script>
      const ws = new WebSocket('ws://' + location.host + '/ws/chat');
      ws.onmessage = e => {
        const d = document.getElementById('messages');
        d.innerHTML += '<p>' + e.data + '</p>';
      };
      function send() {
        const input = document.getElementById('msg');
        ws.send(input.value);
        input.value = '';
      }
    </script>
    </body></html>
"""))

ws!(router, "/ws/chat",
    on_message = (msg::Message) -> begin
        # Echo back the message (in production, broadcast to all clients)
        Message("User: $(msg.data)")
    end,
    on_open = (req::Request) -> @info "Client connected",
    on_close = () -> @info "Client disconnected"
)

server = Async(router; workers=2)
start!(server; host="0.0.0.0", port=8080)
```

### Static + API Hybrid Application

Serve a frontend SPA alongside a JSON API:

```julia
using Mongoose, JSON

Mongoose.encode(::Type{Json}, body) = JSON.json(body)

router = Router()

# --- JSON API ---
route!(router, :get, "/api/v1/config", req -> begin
    Response(Json, Dict("version" => "1.0.0", "features" => ["auth", "search"]))
end)

route!(router, :get, "/api/v1/search", req -> begin
    q = get(req.query, "q", "")
    isempty(q) && return Response(Json, """{"error":"Missing query"}"""; status=400)
    Response(Json, Dict("query" => q, "results" => []))
end)

server = Async(router; nworkers=4)

# Middleware: API-only auth
plug!(server, apikey(keys=Set([ENV["API_KEY"]])); paths=["/api"])

# CORS for API
plug!(server, cors(origins="https://myapp.com"); paths=["/api"])

# Structured logging
plug!(server, logger(structured=true))

# Serve frontend from public/ directory
# Routes take priority, so /api/* is handled by Julia
# Everything else falls through to static files
mount!(server, "public")

start!(server; host="0.0.0.0", port=8080)
```

### Compiled Binary with @router (AOT)

Build a fully self-contained binary using `juliac --trim=safe`:

```julia
# app.jl — compile with: juliac --trim=safe --output-exe myserver app.jl
using Mongoose

@router MyAPI begin
    get("/", req -> Response(Json, """{"status":"ok"}"""))
    get("/users/:id::Int", (req, id) -> Response(Json, """{"id":$id}"""))
    post("/echo", req -> Response(req.body))
    ws("/ws", on_message = msg -> Message("Echo: $(msg.data)"))
end

function main()
    server = Server(MyAPI())
    start!(server; host="0.0.0.0", port=8080)
end

main()
```

The `@router` macro generates a compile-time prefix trie with zero dynamic dispatch,
making it compatible with Julia's AOT compilation. The resulting binary starts in
milliseconds with no JIT warmup.
