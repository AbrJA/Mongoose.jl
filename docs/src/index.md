# Mongoose.jl

**Mongoose.jl** is a Julia package that provides a lightweight and efficient interface for building HTTP servers and web applications. It leverages the [Mongoose C library](https://github.com/cesanta/mongoose) to deliver fast, embeddable web server capabilities directly from Julia code.

## Installation

```julia
] add Mongoose
```

Here is a simple example of how to create an asynchronous server and define a basic route.

```julia
using Mongoose

# Define your routes
router = Router()
route!(router, :get, "/hello", (req) -> Response(200, "Hello!"))

# Create and start the server (AsyncServer runs in background)
server = AsyncServer(router)
start!(server, port=8000, blocking=false)

# When done, shutdown the server
shutdown!(server)
```

## Core Concepts

### Static Routing (AOT)

For applications requiring high performance or Ahead-of-Time (AOT) compilation with `juliac --trim=safe`, Mongoose.jl provides the `@router` macro. This macro generates a zero-allocation, compile-time dispatch function.

```julia
@router MyApi begin
    get("/hello", (req) -> Response(200, "Hello!"))
    get("/echo/:name", (req, name) -> Response(200, "Hi $name"))
    ws("/chat", on_message=(msg) -> "Echo: $(msg.data)")
end

# Use with SyncServer for AOT compatibility
server = SyncServer(MyApi())
```

### Server Types

*   **`AsyncServer`**: Runs the event loop and processes requests in background worker tasks. This is ideal for most applications.
*   **`SyncServer`**: Runs the event loop in the main thread (blocking). Suitable for simple scripts or when you want the server to control the main execution flow (required for AOT).

### Handlers

Handlers are Julia functions that process incoming requests. They must accept at least one argument:

1.  `req::Request`: Contains details about the HTTP request (method, URI, headers, body, etc.).
2.  `params...`: Captured path parameters (optional, based on route definition).

Example with parameters:
```julia
route!(router, :get, "/users/:id", (req, id) -> Response(200, "User $id"))
```

The handler must return a `Response` object.

## Examples

More comprehensive examples demonstrating various use cases and features can be found on the [Examples](examples.md) page.

## API

The full API documentation, including all functions and types, is available on the [API](api.md) page.

## Contributing

Contributions are welcome! Please see the Contributing page for guidelines.

## License

This package is distributed under the GPL-2 License.
