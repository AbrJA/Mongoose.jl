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
        return mg_text_reply(conn, 200, "Hi $(matches.captures[1])")
    else
        return mg_text_reply(conn, 200, "Hi unknown person")
    end
end

mg_register!("GET", "/greet", greet)
```

## POST endpoint with body
```julia
using JSON

function saygoodbye(conn; kwargs...)
    body = mg_body(kwargs[:message])
    dict = JSON.parse(body)
    json = Dict("message" => dict["name"]) |> JSON.json
    return mg_json_reply(conn, 200, json)
end

mg_register!("POST", "/saygoodbye", saygoodbye)
```

## Start server

```julia
mg_serve!()
```

## End server

```julia
mg_shutdown!()
```
