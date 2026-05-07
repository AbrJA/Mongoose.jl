# API Reference

```@meta
CurrentModule = Mongoose
```

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
mount!
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
context!
```

## Utilities

```@docs
Config
TLSConfig
```

## WebSocket Types

```@docs
Message
```

## Middleware

```@docs
cors
ratelimit
bearer
apikey
logger
health
metrics
```

## Errors

```@docs
RouteError
ServerError
BindError
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

