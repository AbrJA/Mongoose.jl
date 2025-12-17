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

This minimal example shows how to create a basic, synchronous HTTP server and define an endpoint.

```julia
using Mongoose

server = SyncServer()

function greet(request::Request, params::Dict{String,String})
    return Response(200, "Content-Type: text/plain\r\n", "Hello from Julia!")
end

function hello(request::Request, params::Dict{String,String})
    body = "{\"message\":\"Hello $(params["name"]) from Julia!\"}"
    return Response(200, Dict("Content-Type" => "application/json"), body)
end

route!(server, :get, "/greet", greet)
route!(server, :get, "/hello/:name", hello)

start!(server, port=8080)
shutdown!(server)
```

## ✨ Core Concepts

Understanding these fundamental components is key to building applications with Mongoose.jl.

### Server Types

Mongoose.jl offers two server models, allowing you to choose the execution flow that best suits your application:

*   **AsyncServer**: Runs the event loop in a background task and processes requests in worker threads. Ideal for most applications.
*   **SyncServer**: Runs the event loop in the main thread (blocking). Useful for simple scripts or when you want full control over the execution flow.

### Request Handling: route!

The route! function is used to map specific incoming HTTP requests to your custom Julia functions (handlers).

```julia
route!(server, :method, "/path", handler)
```

* server: The SyncServer or AsyncServer instance.

* :method: The HTTP verb, e.g., :get, :post, :put, :delete.

* "/path": The URI path, which can include path parameters (e.g., "/users/:id").

* handler: A function with the signature (request::Request, params::Dict{String, String}) -> Response.

### Data Flow: Request and Response

All interaction is centered on these two structs:

* Request: The input data from the client, containing fields like:
    * method (Symbol)
    * uri (String)
    * query (String)
    * headers (Dict)
    * body (String)

* Response: The output data to the client, containing fields like:
    * status (Int)
    * headers (Dict)
    * body (String)

## ⚙️ Advanced Usage

### Concurrency and Multithreading

The AsyncServer is designed for high concurrency. By configuring the number of worker threads, you can efficiently handle multiple requests in parallel.

```julia
using Mongoose

server = AsyncServer(nworkers=4)

function heavy_computation(request, params)
    result = sum(rand(1000000))
    return Response(200, Dict("Content-Type" => "text/plain"), "Result: $result")
end

route!(server, :get, "/compute", heavy_computation)

start!(server, port=8080)
```

> [!NOTE]
> Ensure you start Julia with multiple threads (e.g., `julia -t 4`) to take full advantage of this feature.

### Running Multiple Server Instances

Mongoose.jl supports running multiple, independent server instances simultaneously on different ports.

```julia
using Mongoose

# Create two server instances
server1 = AsyncServer()
server2 = SyncServer() # Mix and match server types

# Define handlers
function handler1(request, params)
    return Response(200, Dict("Content-Type" => "text/plain"), "Server 1: Primary API")
end

function handler2(request, params)
    return Response(200, Dict("Content-Type" => "text/plain"), "Server 2: Admin Interface")
end

# Register routes
route!(server1, :get, "/", handler1)
route!(server2, :get, "/", handler2)

# Start servers on different ports
start!(server1, port=8080, blocking=false)
start!(server2, port=8081, blocking=false)

# ... application code ...

shutdown!(server1)
shutdown!(server2)
```

> [!NOTE]
> Use `shutdown!()` to stop all servers at once. Be careful of letting orphaned servers running in the background. Use this function to ensure all servers are stopped.

## 📚 Documentation

For more information, see the [Mongoose.jl documentation](https://github.com/AbrJA/Mongoose.jl).
