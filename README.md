[![Build Status](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain)

<p align="center">
    <img width="300px" src="logo.png"/>
</p>

**Mongoose.jl** is a Julia package that provides a lightweight and efficient interface for building HTTP servers and web applications. It leverages the [Mongoose C library](https://github.com/cesanta/mongoose) to deliver fast, embeddable web server capabilities directly from Julia code.

## Installation

```julia
] add Mongoose
```

## Quick Start

Here is a simple example of how to create a basic HTTP server.

```julia
using Mongoose

# Define a request handler
function greet(request::Request)
    body = "{\"message\":\"Hello World from Julia!\"}"
    return Response(200, Dict("Content-Type" => "application/json"), body)
end

# Register a route
route!(greet, "GET", "/hello")

# Start the server (defaults to localhost:8080, async=true)
start!()

# ... do other things ...

# Stop the server
shutdown!()
```

## Core Concepts

### Servers

Mongoose.jl supports two types of servers:

*   **AsyncServer** (Default): Runs the event loop in a background task and processes requests in worker threads. Ideal for most applications.
*   **SyncServer**: Runs the event loop in the main thread (blocking). Useful for simple scripts or when you want full control over the execution flow.

### Routing

Use `route!` to map HTTP methods and paths to handler functions.

```julia
route!(handler_function, "METHOD", "/path")
```

Handler functions should accept a `Request` object and return a `Response` object.

### Request & Response

*   **Request**: Contains `method`, `uri`, `query`, `headers`, and `body`.
*   **Response**: Constructed with `status` (Int), `headers` (Dict), and `body` (String).

## Advanced Usage

### Multiple Instances

You can create and run multiple server instances simultaneously on different ports.

```julia
using Mongoose

# Create two server instances
server1 = AsyncServer()
server2 = AsyncServer()

# Define handlers
function handler1(req)
    return Response(200, Dict(), "Server 1")
end

function handler2(req)
    return Response(200, Dict(), "Server 2")
end

# Register routes on specific servers
route!(server1, handler1, "GET", "/")
route!(server2, handler2, "GET", "/")

# Start servers on different ports
start!(server=server1, port=8080)
start!(server=server2, port=8081)

# ...

shutdown!(server1)
shutdown!(server2)
```

### Multithreading

`AsyncServer` can utilize multiple worker threads to handle requests concurrently. This is configured via the `nworkers` parameter during server initialization.

```julia
using Mongoose

# Create a server with 4 worker threads
server = AsyncServer(nworkers=4)

function heavy_computation(req)
    # This will run on one of the worker threads
    result = sum(rand(1000000))
    return Response(200, Dict(), "Result: $result")
end

route!(server, heavy_computation, "GET", "/compute")

start!(server=server, port=8080)
```

> [!NOTE]
> Ensure you start Julia with multiple threads (e.g., `julia -t 4`) to take full advantage of this feature.

## API Reference

### `start!(; server=default_server(), host="127.0.0.1", port=8080, async=true)`
Starts the Mongoose HTTP server.

### `shutdown!(; server=default_server())`
Stops the running Mongoose HTTP server.

### `route!(server, handler, method, path)`
Registers a route on the specified server. If `server` is omitted, the default server is used.
