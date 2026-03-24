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

JSON support requires `JSON.jl` to be installed. It loads automatically as a package extension.

```julia
using Mongoose, JSON

struct UserProfile
    username::String
    age::Int
    active::Bool
end

router = Router()

# Parse JSON body into a Dict
route!(router, :post, "/user/dict", req -> begin
    data = json_body(req)
    name = get(data, "username", "Guest")
    JsonResponse(Dict("message" => "Hello, $name"))
end)

# Parse JSON body into a struct
route!(router, :post, "/user/struct", req -> begin
    profile = json_body(req, UserProfile)
    JsonResponse(Dict("received" => profile.username, "age" => profile.age))
end)

# Custom status code
route!(router, :post, "/user/create", req -> begin
    data = json_body(req)
    JsonResponse(Dict("id" => 42, "created" => true); status=201)
end)

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## Parse Query into a Struct

Use `parse_into` to deserialize a query string or `Dict{String,String}` into a typed struct. Supports `String`, numeric types, `Bool`, and `Union{T, Nothing}` for optional fields.

```julia
using Mongoose

struct SearchQuery
    q::String
    page::Int
    limit::Union{Int, Nothing}
end

router = Router()

route!(router, :get, "/search", req -> begin
    params = parse_params(query(req))
    search = parse_into(SearchQuery, params)
    Response(200, ContentType.text, "Searching '$(search.q)' page $(search.page)")
end)

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## WebSocket Echo Server

Register WebSocket endpoints with `ws!`. The `on_message` handler receives a `WsTextMessage` or `WsBinaryMessage`.

```julia
using Mongoose

router = Router()

ws!(router, "/echo",
    on_message = msg -> begin
        if msg isa WsTextMessage
            return "Echo: $(msg.data)"
        elseif msg isa WsBinaryMessage
            return msg.data  # Echo binary data back
        end
        return nothing
    end,
    on_open  = () -> println("Client connected"),
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
use!(server, auth_bearer(token -> token == "my-secret-token"))

start!(server, port=8080, blocking=false)
```

## API Key Authentication

Protect endpoints with an API key header check:

```julia
using Mongoose

router = Router()
route!(router, :get, "/internal", req -> Response(200, ContentType.text, "Internal data"))

server = AsyncServer(router)
use!(server, auth_api_key(header_name="X-API-Key", keys=Set(["key-abc", "key-xyz"])))

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

Middleware can attach data to the request context, which handlers can access:

```julia
using Mongoose

struct UserLookup <: Mongoose.Middleware
    db::Dict{String, String}
end

function (mw::UserLookup)(request, params, next)
    token = header(request, "Authorization")
    if token !== nothing
        user = get(mw.db, replace(token, "Bearer " => ""), nothing)
        if user !== nothing
            context(request)[:user] = user
        end
    end
    return next()
end

router = Router()
route!(router, :get, "/me", req -> begin
    user = get(context(req), :user, "anonymous")
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
    ws("/chat", on_message = msg -> "Echo: $(msg.data)")
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
    JsonResponse(Dict("id" => id, "name" => "User $id"))
end)

route!(router, :post, "/api/users", req -> begin
    user = json_body(req, CreateUser)
    JsonResponse(Dict("created" => user.name); status=201)
end)

# WebSocket
ws!(router, "/ws/notifications",
    on_message = msg -> """{"ack": true}""",
    on_open    = () -> @info "WS client connected"
)

# Server with full middleware stack
server = AsyncServer(router; workers=4)
use!(server, logger(threshold_ms=100))
use!(server, cors(origins="https://myapp.com"))
use!(server, rate_limit(max_requests=200, window_seconds=60))
use!(server, static_files("public"; prefix="/static"))

start!(server, port=8080, blocking=false)
```
