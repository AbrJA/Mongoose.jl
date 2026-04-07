# API Reference

## Server Types

```@docs
AsyncServer
SyncServer
```

## Lifecycle

```@docs
start!
shutdown!
plug!
error_response!
```

## Routing

```@docs
Router
route!
ws!
```

## Request & Response

```@docs
Request
Response
ContentType
Binary
context!
```

## Utilities

```@docs
ServerConfig
```

## WebSocket Types

```@docs
Message
```

## Middleware

```@docs
cors
rate_limit
bearer_token
api_key
logger
health
metrics
```

## JSON

JSON support is enabled by extending `render_body`:

```julia
using JSON
Mongoose.render_body(::Type{Json}, body) = JSON.json(body)
```

Then use `Response(Json, value)` anywhere in your handlers.

## Static Router

```@docs
@router
```

## All Symbols

```@autodocs
Modules = [Mongoose]
Order = [:constant, :type, :function, :macro]
```
