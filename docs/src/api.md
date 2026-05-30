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
StreamResponse
Headers
context!
Cookie
serialize_cookie
parse_cookies
```

## Utilities

```@docs
Config
TLSConfig
ServiceRegistry
register!
service
RouteGroup
group
register_group!
```

## WebSocket Types

```@docs
Message
```

## SSE (Server-Sent Events)

```@docs
SSEWriter
event!
sse_response
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
security
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

