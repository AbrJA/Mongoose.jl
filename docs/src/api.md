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
use!
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
header
body
query
getcontext!
parse_query
```

## Utilities

```@docs
Mongoose.query
parse_query
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
