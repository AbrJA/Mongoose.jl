[![Build Status](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain)

<p align="center">
    <img width="200px" src="https://github.com/user-attachments/assets/40a66324-a904-40d7-8b00-c996f7c3e34c"/>
</p>

## Abstract

**Mongoose.jl** is a Julia package that provides a lightweight and efficient interface for building HTTP servers and web applications. It leverages the [Mongoose C library](https://github.com/cesanta/mongoose) to deliver fast, embeddable web server capabilities directly from Julia code. The package is designed for simplicity and ease of use, making it suitable for rapid prototyping, educational purposes, and lightweight web services. With Mongoose.jl, users can define routes, handle HTTP requests, and serve dynamic or static content with minimal setup.

## Install

```julia
] add https://github.com/AbrJA/Mongoose.jl.git
```

## Example: Simple HTTP server

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
