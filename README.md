# Mongoose

[![Build Status](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain)

## Install

```julia
] add https://github.com/AbrJA/Mongoose.jl.git
```

# Example: Simple HTTP Server with Mongoose.jl

This example demonstrates how to use the `Mongoose.jl` package to create a basic HTTP server in Julia. The server registers a single route (`/hello`) that responds to GET requests with a JSON message.

- Loading library

```julia
using Mongoose
```

- JSON response

```julia
const json = "{\"message\":\"Hello World from Julia!\"}"
```

- Request handler

```julia
function greet(conn, request)
    @info mg_body(request)
    mg_json_reply(conn, 200, json)
end
```

- Route registration

```julia
mg_register!("GET", "/hello", greet)
```

- Start server

```julia
mg_serve()
```

- Shoutdown server

```julia
mg_shutdown()
```
