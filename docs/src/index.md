# Mongoose.jl

**Mongoose.jl** is a Julia package that provides a lightweight and efficient interface for building HTTP servers and web applications. It leverages the [Mongoose C library](https://github.com/cesanta/mongoose) to deliver fast, embeddable web server capabilities directly from Julia code.

## Installation

```julia
] add Mongoose
```

## Quick Start

Here is a simple example of how to create a synchronous server and define a basic route.

```julia
using Mongoose

# Create a synchronous server
server = SyncServer()

# Define a handler function
function hello_world(req::Request, params::Dict{String,String})
    return Response(200, Dict("Content-Type" => "text/plain"), "Hello from Mongoose.jl!")
end

# Register the route
route!(server, :get, "/hello", hello_world)

# Start the server
start!(server, port=8000)

# When done, shutdown the server
shutdown!(server)
```

## Core Concepts

### Server Types

*   **`SyncServer`**: Runs the event loop in the main thread. This is a blocking operation, suitable for simple scripts or when you want the server to control the main execution flow.
*   **`AsyncServer`**: Runs the event loop in a background task. This allows the main thread to continue executing other code, making it ideal for interactive sessions or more complex applications.

### Handlers

Handlers are Julia functions that process incoming requests. They must accept two arguments:

1.  `req::Request`: Contains details about the HTTP request (method, URI, headers, body, etc.).
2.  `params::Dict{String,String}`: Contains path parameters captured from the URI.

The handler must return a `Response` object.

## Examples

More comprehensive examples demonstrating various use cases and features can be found on the [Examples](examples.md) page.

## API

The full API documentation, including all functions and types, is available on the [API](api.md) page.

## Contributing

Contributions are welcome! Please see the Contributing page for guidelines.

## License

This package is distributed under the GPL-2 License.
