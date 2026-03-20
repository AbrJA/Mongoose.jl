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

function greet(req::Request, params::Dict{String,String})
    # Use built-in query parameter parsing if available, or manual:
    name = get(parse_into(Dict, req.query), "name", "Guest")
    return Response(200, "Hi $name")
end

route!(router, :get, "/greet", greet)

server = Server(router)
start!(server, port=8080)
```

## POST Endpoint with JSON Body

This example shows how to handle a POST request and parse a JSON body.

```julia
using Mongoose

router = Router()

function saygoodbye(req::Request, params::Dict{String,String})
    data = json_body(req)
    name = get(data, "name", "Friend")
    return json_response(Dict("message" => "Goodbye, $name!"))
end

route!(router, :post, "/saygoodbye", saygoodbye)

server = Server(router)
start!(server, port=8081)
```

## Async Server with Multithreading

For higher performance, use `AsyncServer` and start Julia with multiple threads (`julia -t 4`).

```julia
using Mongoose

router = Router()

function heavy_task(req::Request, params::Dict{String,String})
    # Simulate work
    s = sum(rand(1000000))
    return Response(200, "Computed: $s")
end

route!(router, :get, "/compute", heavy_task)

server = Server(router)

# Start with 4 worker threads, non-blocking
start!(server, port=8082, workers=4, blocking=false)

# Do other things...

# Shutdown when done
shutdown!(server)
```

## Path Parameters

Mongoose.jl supports dynamic path parameters.

```julia
using Mongoose

router = Router()

function get_user(req::Request, params::Dict{String,String})
    user_id = params["id"]
    return Response(200, "User ID: $user_id")
end

# Define route with parameter :id
route!(router, :get, "/users/:id", get_user)

server = Server(router)
start!(server, port=8083)
```
