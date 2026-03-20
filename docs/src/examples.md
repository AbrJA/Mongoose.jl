# Examples

## Basic Setup

First, load the package:

```julia
using Mongoose
```

## GET Endpoint with Query Parameters

This example demonstrates how to parse query parameters from the request URI.

```julia
using Mongoose

router = Router()

function greet(req::Request)
    # req.query contains the raw query string "name=Guest"
    # parse_into turns it into a Dict or a Struct
    params = parse_into(Dict, req.query)
    name = get(params, "name", "Guest")
    return Response(200, "Hi $name")
end

route!(router, :get, "/greet", greet)

server = AsyncServer(router)
start!(server, port=8080, blocking=false)
```

## POST Endpoint with JSON Body

This example shows how to handle a POST request and parse a JSON body.

```julia
using Mongoose

router = Router()

function saygoodbye(req::Request)
    data = json_body(req)
    name = get(data, "name", "Friend")
    return json_response(Dict("message" => "Goodbye, $name!"))
end

route!(router, :post, "/saygoodbye", saygoodbye)

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
    Response(200, "User ID (String): $id")
end)

# Typed parameter (Int)
route!(router, :get, "/items/:id::Int", (req, id) -> begin
    Response(200, "Item ID (Int): $id")
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
