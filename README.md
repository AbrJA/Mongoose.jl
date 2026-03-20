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

Mongoose.jl uses a decoupled architecture: define your **Router**, then pass it to a **Server**.

```julia
using Mongoose

# 1. Define your routes using an HttpRouter
router = HttpRouter()

route!(router, :get, "/hello", (req) -> begin
    Response(200, "Hello from Mongoose.jl!")
end)

route!(router, :get, "/greet/{name}", (req, name) -> begin
    body = Dict("message" => "Hello $name!", "status" => "ok")
    json_response(body)
end)

# 2. Create the server and start it
server = Server(router)

# Start with 4 worker threads
start!(server, port=8080, workers=4)
```

## ✨ Core Concepts

### 1. Routers
Mongoose.jl provides two ways to handle routing for both HTTP and WebSockets:

*   **HttpRouter / WsRouter**: Standard dynamic path-based routing. Routes can be added or modified at runtime using `route!` or `ws!`.
*   **StaticHttpRouter / StaticWsRouter**: Created via the `@router` and `@wsrouter` macros. They use compile-time dispatch and are required for **AOT compilation** with `juliac --trim=safe`.

```julia
# Static HTTP Router Example
@router MyApi begin
    GET("/", (req) -> Response(200, "Static Hello"))
end

# Static WS Router Example
@wsrouter MyWs begin
    WS("/chat", on_message=(msg) -> "Echo: $(msg.data)")
end

server = Server(MyApi(), static_ws=MyWs())
start!(server, port=8081)
```

### 2. Server Types
You can choose the execution model that fits your needs:
*   **AsyncServer**: Processes requests in a background worker pool. This is the default when calling `Server(router)`.
*   **SyncServer**: Processes requests in the main thread (blocking). Ideal for low-latency or simple scripts.

### 3. Request and Response
- **`Request`**: Contains `method`, `uri`, `headers`, and `body`.
- **`Response`**: Constructed with a status code, optional headers (Dict or String), and a body.

## 🛠 Features

### Middleware
Mongoose.jl includes built-in middleware for common tasks like CORS and Rate Limiting.

```julia
server = Server(router)
use!(server, cors_middleware(origins="*"))
use!(server, rate_limit_middleware(requests=100, window=60))
```

### WebSocket Support
Seamlessly integrate WebSockets into your application.

```julia
ws_router = WsRouter()
ws!(ws_router, "/chat", on_message=(msg) -> "Echo: $(msg.data)")

server = Server(router, ws_router=ws_router)
start!(server, port=8080)
```

### JSON Support
Utilities for handling JSON payloads and responses.

```julia
# Parse JSON body
data = json_body(request)

# Send JSON response
json_response(Dict("key" => "value"))
```

## 🏗 Ahead-of-Time (AOT) Compilation
Mongoose.jl is designed to be fully compatible with `juliac --trim=safe`. By using the `@router` macro, you can compile your entire web application into a tiny, standalone binary with no dynamic dispatch.

## 📚 Documentation

For more information, see the [Mongoose.jl documentation](https://AbrJA.github.io/Mongoose.jl/dev).
