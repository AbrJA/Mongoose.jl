# Examples

## Basic Setup

First, load the package:

```julia
using Mongoose
```

## GET Endpoint with Query Parameters

This example demonstrates how to lookup query parameters from the request URI using the `query` helper.

```julia
using Mongoose

router = Router()

function greet(req::Request)
    # Use query() to get parameters from "?name=Guest"
    name = query(req, "name")
    return Response(200, ContentType.text, "Hi $(something(name, "Guest"))")
end

route!(router, :get, "/greet", greet)

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## POST Endpoint with JSON Body

This example shows how to handle a POST request and parse a JSON body into a Dict or a Struct.

```julia
using Mongoose

# Define a struct for your data
struct UserProfile
    username::String
    age::Int
    active::Bool
end

router = Router()

# Example 1: Parsing into a Dict
route!(router, :post, "/user/dict", (req) -> begin
    data = json_body(req)
    name = get(data, "username", "Guest")
    return json_response(Dict("message" => "Hello $name"))
end)

# Example 2: Parsing into a Struct (requires JSON.jl loaded)
route!(router, :post, "/user/struct", (req) -> begin
    profile = json_body(req, UserProfile)
    return json_response(Dict("received" => profile.username))
end)

server = AsyncServer(router)
start!(server, port=8081, blocking=false)
```

## Async Server with Multithreading

For higher performance, use `AsyncServer` and start Julia with multiple threads (`julia -t 4`).

```julia
using Mongoose

router = Router()

function heavy_task(req::Request)
    # Simulate work
    s = sum(rand(1000000))
    return Response(200, "Computed: $s")
end

route!(router, :get, "/compute", heavy_task)

# Start with 4 worker threads
server = AsyncServer(router; workers=4)
start!(server, port=8082, blocking=false)

# Shutdown when done
shutdown!(server)
```

## Path Parameters and Types

Mongoose.jl supports dynamic path parameters with optional type annotations.

```julia
using Mongoose

router = Router()

# Basic string parameter
route!(router, :get, "/users/:id", (req, id) -> begin
    Response(200, ContentType.text, "User ID: $id")
end)

# Typed parameter (Int) - path segment is auto-parsed
route!(router, :get, "/items/:id::Int", (req, id) -> begin
    Response(200, ContentType.text, "Item ID (Int): $id")
end)

server = AsyncServer(router)
start!(server, port=8083, blocking=false)
```

## WebSocket Echo

Mongoose.jl supports WebSockets directly on the same router.

```julia
using Mongoose

router = Router()

ws!(router, "/chat", on_message=(msg) -> begin
    if msg isa WsTextMessage
        return "Echo: $(msg.data)"
    end
    return nothing
end)

server = AsyncServer(router)
start!(server, port=8084, blocking=false)
```
## Middleware

Mongoose.jl includes built-in middleware for logging, security, and performance.

```julia
using Mongoose

router = Router()
route!(router, :get, "/api/data", (req) -> Response(200, ContentType.json, "{\"status\":\"ok\"}"))

server = AsyncServer(router)

# 1. Logging all requests
use!(server, logger())

# 2. CORS support
use!(server, cors(origins="*"))

# 3. Rate Limiting (100 requests per 60 seconds per IP)
use!(server, rate_limit(max_requests=100, window_seconds=60))

# 4. Bearer Token Auth
use!(server, auth_bearer(token -> token == "secret-123"))

start!(server, port=8085, blocking=false)
```

## Serving Static Files

Use the `static_files` middleware to serve a directory of HTML, CSS, and JS files.

```julia
using Mongoose

# Serves all files in the "public" directory under the "/static" prefix
# e.g., GET /static/style.css -> public/style.css
# e.g., GET /static/           -> public/index.html
server = SyncServer(Router())
use!(server, static_files("public"; prefix="/static", index="index.html"))

start!(server, port=8086)
```
