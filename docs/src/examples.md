# Examples

## Hello World

The simplest possible Mongoose.jl server:

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> Response(200, ContentType.text, "Hello, World!"))

server = SyncServer(router)
start!(server, port=8080)
```

## REST API with Path Parameters

Dynamic path segments are captured with `:name` syntax. Add type annotations for automatic parsing:

```julia
using Mongoose

router = Router()

# String parameter (default)
route!(router, :get, "/greet/:name", (req, name) -> begin
    Response(200, ContentType.text, "Hello, $name!")
end)

# Typed integer parameter
route!(router, :get, "/users/:id::Int", (req, id) -> begin
    Response(200, ContentType.json, """{"id": $id, "type": "$(typeof(id))"}""")
end)

# Float parameter
route!(router, :get, "/price/:amount::Float64", (req, amount) -> begin
    tax = amount * 0.16
    Response(200, ContentType.json, """{"amount": $amount, "tax": $tax}""")
end)

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## Query Parameters

Use `query(req, key)` to access URL-decoded query parameters. Parsed parameters are cached on first access for efficient repeated lookups.

```julia
using Mongoose

router = Router()

route!(router, :get, "/search", req -> begin
    q    = query(req, "q")
    page = query(req, "page")

    q === nothing && return Response(400, ContentType.text, "Missing ?q= parameter")

    p = page === nothing ? 1 : parse(Int, page)
    Response(200, ContentType.json, """{"query": "$q", "page": $p}""")
end)

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## JSON Request and Response

JSON support requires `JSON.jl`. Extend `render_body` once at the top of your app to enable `Response(Json, ...)` with automatic Content-Type.

```julia
using Mongoose, JSON

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

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

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## Parse Query into a Struct

Use `Mongoose.query(T, str)` to deserialize a query string into a typed struct. Supports `String`, numeric types, `Bool`, and `Union{T, Nothing}` for optional fields.

```julia
using Mongoose

struct SearchQuery
    q::String
    page::Int
    limit::Union{Int, Nothing}
end

router = Router()

route!(router, :get, "/search", req -> begin
    search = Mongoose.query(SearchQuery, req.query)
    Response(200, ContentType.text, "Searching '$(search.q)' page $(search.page)")
end)

server = AsyncServer(router)
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

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## Middleware Stack

Middleware executes in registration order. Each middleware can inspect the request, short-circuit with a response, or pass through to the next handler.

```julia
using Mongoose

router = Router()
route!(router, :get, "/api/data", req -> begin
    Response(200, ContentType.json, """{"status": "ok"}""")
end)

server = AsyncServer(router)

# 1. Log all requests (method, URI, status, duration in ms)
use!(server, logger())

# 2. CORS headers + OPTIONS preflight handling
use!(server, cors(origins="https://example.com"))

# 3. Rate limiting: 100 requests per 60 seconds per client IP
use!(server, rate_limit(max_requests=100, window_seconds=60))

# 4. Bearer token authentication
use!(server, bearer_token(token -> token == "my-secret-token"))

start!(server, port=8080, blocking=false)
```

## API Key Authentication

Protect endpoints with an API key header check:

```julia
using Mongoose

router = Router()
route!(router, :get, "/internal", req -> Response(200, ContentType.text, "Internal data"))

server = AsyncServer(router)
use!(server, api_key(header_name="X-API-Key", keys=Set(["key-abc", "key-xyz"])))

start!(server, port=8080, blocking=false)
```

## Logger with Threshold

Only log requests that exceed a duration threshold — useful for identifying slow endpoints:

```julia
using Mongoose

router = Router()
route!(router, :get, "/fast", req -> Response(200, ContentType.text, "fast"))
route!(router, :get, "/slow", req -> begin
    sleep(0.1)
    Response(200, ContentType.text, "slow")
end)

server = AsyncServer(router)

# Only log requests taking longer than 50ms
use!(server, logger(threshold_ms=50))

start!(server, port=8080, blocking=false)
```

## Serving Static Files

Serve a directory of HTML, CSS, JS, and other assets:

```julia
using Mongoose

server = AsyncServer(Router())

# Serve files from "public/" directory under the "/static" URL prefix
# GET /static/style.css  →  public/style.css
# GET /static/            →  public/index.html
use!(server, static_files("public"; prefix="/static", index="index.html"))

start!(server, port=8080, blocking=false)
```

## Request Context

Middleware can attach data to the request context via `getcontext!`, which handlers can access:

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
            getcontext!(request)[:user] = user
        end
    end
    return next()
end

router = Router()
route!(router, :get, "/me", req -> begin
    user = get(getcontext!(req), :user, "anonymous")
    Response(200, ContentType.text, "Hello, $user!")
end)

server = AsyncServer(router)
use!(server, UserLookup(Dict("token-123" => "Alice", "token-456" => "Bob")))

start!(server, port=8080, blocking=false)
```

## Async Server with Multiple Workers

For higher throughput, start Julia with multiple threads and configure the worker count:

```julia
using Mongoose

router = Router()

route!(router, :get, "/compute", req -> begin
    result = sum(rand(1_000_000))
    Response(200, ContentType.text, "Computed: $result")
end)

# 8 worker tasks processing requests concurrently
server = AsyncServer(router; workers=8)
start!(server, port=8080, blocking=false)
```

Start Julia with threads: `julia -t 8`

## Static Router (AOT Compilation)

For ahead-of-time compiled binaries with `juliac --trim=safe`, use the `@router` macro instead of `Router()`:

```julia
using Mongoose

@router MyApi begin
    get("/", req -> Response(200, ContentType.text, "Hello from AOT!"))
    get("/users/:id::Int", (req, id) -> Response(200, ContentType.text, "User $id"))
    post("/echo", req -> Response(200, ContentType.text, body(req)))
    ws("/chat", on_message = msg -> Message("Echo: $(msg.data)"))
end

server = SyncServer(MyApi())
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
route!(router, :get, "/health", req -> Response(200, ContentType.text, "ok"))

# JSON API
route!(router, :get, "/api/users/:id::Int", (req, id) -> begin
    Response(Json, Dict("id" => id, "name" => "User $id"))
end)

route!(router, :post, "/api/users", req -> begin
    data = JSON.parse(req.body)
    name = get(data, "name", "")
    Response(Json, Dict("created" => name); status=201)
end)

# WebSocket
ws!(router, "/ws/notifications",
    on_message = (msg::Message) -> Message("""{"ack": true}"""),
    on_open    = (req::Request) -> @info "WS client connected"
)

# Server with full middleware stack
server = AsyncServer(router; workers=4)
use!(server, logger(threshold_ms=100))
use!(server, cors(origins="https://myapp.com"))
use!(server, rate_limit(max_requests=200, window_seconds=60))
use!(server, static_files("public"; prefix="/static"))

start!(server, port=8080, blocking=false)
```

## Custom Error Handler

Handle errors globally with a custom error handler:

```julia
using Mongoose, JSON

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

router = Router()

route!(router, :get, "/fail", req -> error("Something broke"))
route!(router, :get, "/ok", req -> Response(200, "All good"))

server = AsyncServer(router; request_timeout_ms=5000)

on_error!(server, (req, err) -> begin
    @error "Unhandled error" uri=req.uri exception=err
    Response(Json, Dict("error" => "Internal error", "uri" => req.uri); status=500)
end)

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

server = AsyncServer(router)

# Auth only for /api and /admin routes
use!(server, bearer_token(t -> t == "secret"); paths=["/api", "/admin"])

# Rate limit only expensive API endpoints
use!(server, rate_limit(max_requests=10, window_seconds=60); paths=["/api"])

# Logger for everything
use!(server, logger(structured=true))

start!(server, port=8080, blocking=false)
```

## Structured JSON Logging

Emit structured JSON log lines for machine-parsable logging:

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> Response(200, "ok"))

server = AsyncServer(router)
use!(server, logger(structured=true, output=open("access.log", "a")))

start!(server, port=8080, blocking=false)
```

Each log line is a JSON object:
```json
{"method":"GET","uri":"/","status":200,"duration_ms":0.42,"ts":"2025-01-15T10:30:00.123"}
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

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```
