[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://AbrJA.github.io/Mongoose.jl/dev)
[![Build Status](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain)

<p align="center">
    <img width="300px" src="logo.png"/>
</p>

# 🚀 Mongoose.jl: A Lightweight HTTP Server for Julia

**Mongoose.jl** is a Julia package that provides a lightweight and efficient interface for building HTTP servers and web applications. It leverages the [Mongoose C library](https://github.com/cesanta/mongoose) to deliver fast, embeddable web server capabilities directly from Julia code.

## 📦 Installation

```julia
] add Mongoose
```

## ⚡ Quick Start: Your First Server

Mongoose.jl uses a decoupled architecture: define your **Router**, then pass it to a **Server** types (`AsyncServer` or `SyncServer`).

```julia
using Mongoose

# 1. Define your routes using a Router
router = Router()

route!(router, :get, "/hello", (req) -> begin
    Response(200, "Hello from Mongoose.jl!")
end)

# Capture path parameters with type annotations
route!(router, :get, "/greet/:name", (req, name) -> begin
    body = Dict("message" => "Hello $name!", "status" => "ok")
    json_response(body)
end)

route!(router, :get, "/users/:id::Int", (req, id) -> begin
    Response(200, "User ID is $id (type $(typeof(id)))")
end)

# 2. Create the server and start it
# AsyncServer runs in background worker threads (default 4)
server = AsyncServer(router; workers=4)

# Start the server. blocking=true blocks the current thread (useful for AOT).
start!(server, port=8080, blocking=false)
```

## ✨ Core Concepts

### 1. Routers
Mongoose.jl provides a flexible `Router` that handles both HTTP and WebSockets:

*   **Router**: Dynamic path-based routing. Routes can be added or modified at runtime using `route!` or `ws!`.
*   **@router**: A macro to generate a static router. This uses compile-time dispatch and is required for **AOT compilation** with `juliac --trim=safe`.

```julia
# Static Router Example
@router MyApi begin
    get("/", (req) -> Response(200, "Static Hello"))
    ws("/chat", on_message=(msg) -> "Echo: $(msg.data)")
end

# Use with SyncServer for AOT compatibility
server = SyncServer(MyApi())
start!(server, port=8081)
```

### 2. Server Types
You can choose the execution model that fits your needs:
*   **AsyncServer**: Processes requests in a background worker pool.
*   **SyncServer**: Processes requests in the main thread (blocking). Ideal for low-latency, simple scripts, or AOT-compiled binaries.

### 3. Request and Response
- **`Request`**: Contains `method`, `uri`, `headers`, and `body`.
- **`Response`**: Constructed with a status code, optional headers (Dict or String), and a body.

## 🛠 Features

### Middleware

Mongoose.jl includes built-in middleware for common tasks. Middleware can be added to any server using `use!`.

```julia
# Logging: logs method, URI, status, and time (ms)
use!(server, logger())

# CORS: handles OPTIONS and adds headers
use!(server, cors(origins="*"))

# Rate Limiting: 100 requests per 60s per client IP
use!(server, rate_limit(max_requests=100, window_seconds=60))

# Serving Static Files
use!(server, static_files("public"; prefix="/static"))

# Authentication
use!(server, auth_bearer(token -> token == "secret-123"))
```

### Request Utilities

Handlers receive a `Request` or `ViewRequest`. Use these helpers to access data efficiently:

```julia
route!(router, :get, "/search", (req) -> begin
    q = query(req, "q")          # Get ?q=... (URL-decoded)
    user = context(req)[:user]   # Access request context
    println("Body: ", body(req)) # Raw request body
    
    Response(200, ContentType.json, "{\"ok\": true}")
end)
```

### WebSocket Support
Seamlessly integrate WebSockets into your application.

```julia
router = Router()
ws!(router, "/chat", on_message=(msg) -> "Echo: $(msg.data)")

server = AsyncServer(router)
start!(server, port=8080)
```

### JSON Support

Utilities for handling JSON payloads. These are optimized to use `JSON.jl` when available.

```julia
# Parse JSON body into a Dict
data = json_body(request)

# Send JSON response with correct Content-Type
json_response(Dict("status" => "ok"))
```

## 🏗 Ahead-of-Time (AOT) Compilation
Mongoose.jl is designed to be fully compatible with `juliac --trim=safe`. By using the `@router` macro and `SyncServer`, you can compile your entire web application into a tiny, standalone binary with no dynamic dispatch.

## 📚 Documentation

For more information, see the [Mongoose.jl documentation](https://AbrJA.github.io/Mongoose.jl/dev).
