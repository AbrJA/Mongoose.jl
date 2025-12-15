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

server = SyncServer()

function greet(req::Request, params::Dict{String,String})
    # Simple query parsing (for demonstration)
    # In a real app, you might want a more robust query parser
    query_str = req.query
    name = "unknown person"

    if !isempty(query_str)
        # simplistic parsing looking for "name=..."
        m = match(r"name=([^&]*)", query_str)
        if m !== nothing
            name = m.captures[1]
        end
    end

    return Response(200, Dict("Content-Type" => "text/plain"), "Hi $name")
end

route!(server, :get, "/greet", greet)

# Start server on port 8080
start!(server, port=8080)
```

## POST Endpoint with JSON Body

This example shows how to handle a POST request and parse a JSON body.

```julia
using Mongoose
using JSON

server = SyncServer()

function saygoodbye(req::Request, params::Dict{String,String})
    try
        data = JSON.parse(req.body)
        name = get(data, "name", "Friend")

        response_data = Dict("message" => "Goodbye, $name!")
        return Response(200, Dict("Content-Type" => "application/json"), JSON.json(response_data))
    catch e
        return Response(400, Dict("Content-Type" => "text/plain"), "Invalid JSON")
    end
end

route!(server, :post, "/saygoodbye", saygoodbye)

start!(server, port=8081)
```

## Async Server with Multithreading

For higher performance, use `AsyncServer` and start Julia with multiple threads (`julia -t 4`).

```julia
using Mongoose

# Create an async server with 4 worker threads
server = AsyncServer(nworkers=4)

function heavy_task(req::Request, params::Dict{String,String})
    # Simulate work
    s = sum(rand(1000000))
    return Response(200, Dict("Content-Type" => "text/plain"), "Computed: $s")
end

route!(server, :get, "/compute", heavy_task)

# Start non-blocking
start!(server, port=8082, blocking=false)

# Do other things...

# Shutdown when done
shutdown!(server)
```

## Path Parameters

Mongoose.jl supports dynamic path parameters.

```julia
using Mongoose

server = SyncServer()

function get_user(req::Request, params::Dict{String,String})
    user_id = params["id"]
    return Response(200, Dict("Content-Type" => "text/plain"), "User ID: $user_id")
end

# Define route with parameter :id
route!(server, :get, "/users/:id", get_user)

start!(server, port=8083)
```
