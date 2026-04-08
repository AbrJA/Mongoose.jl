# API Reference

## Server Types

```@docs
Async
Server
```

## Lifecycle

```@docs
start!
shutdown!
plug!
fail!
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
Binary
context!
```

## Utilities

```@docs
Config
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

JSON support is enabled by extending `encode`:

```julia
using JSON
Mongoose.encode(::Type{Json}, body) = JSON.json(body)
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
