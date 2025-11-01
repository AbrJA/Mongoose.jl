# Examples

Loading the library

```julia
using Mongoose
```

## GET endpoint with query params

```julia
function greet(conn; kwargs...)
    query = mg_query(kwargs[:message])
    matches = match(r"name=([^&]*)", query)
    if !isnothing(matches)
        return Response(200, Dict("Content-Type" => "text/plain"), "Hi $(matches.captures[1])")
    else
        return Response(200, Dict("Content-Type" => "text/plain"), "Hi unknown person")
    end
end

register("GET", "/greet", greet)
```

## POST endpoint with body
```julia
using JSON

function saygoodbye(request; kwargs...)
    body = JSON.parse(request.body)
    json = Dict("message" => body["name"]) |> JSON.json
    return Response(200, Dict("Content-Type" => "application/json"), json)
end

register("POST", "/saygoodbye", saygoodbye)
```

## Start server

```julia
serve()
```

## End server

```julia
shutdown()
```
