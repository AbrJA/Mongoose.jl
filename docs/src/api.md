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
header
body
query
context
```

## Utilities

```@docs
parse_params
parse_into
```

## WebSocket Types

```@docs
WsMessage
WsTextMessage
WsBinaryMessage
```

## Middleware

```@docs
cors
rate_limit
auth_bearer
auth_api_key
logger
static_files
```

## JSON (Extension)

```@docs
JsonResponse
json_body
```

## Static Router

```@docs
@router
```

## All Symbols

```@autodocs
Modules = [Mongoose]
Order = [:constant, :type, :function, :macro]
```
