# API Reference

```@meta
CurrentModule = Mongoose
```

## App

```@docs
App
start!
shutdown!
```

## Routing

```@docs
Router
route!
ws!
freeze!
isfrozen
RouteGroup
group
group!
mount!
match_route
match_route_exact
get_handler
get_endpoint
Matched
NotFound
MethodNotAllowed
RouteResult
MethodMap
post!
patch!
options!
head!
```

## Request Processing

```@docs
invoke_request
RequestContext
terminal_for
error_response
execute_pipeline
AbstractRequest
```

## Request & Response

```@docs
Request
Response
StreamResponse
Headers
Cookie
```

## Response Helpers

```@docs
json
html
text
redirect
bake
```

## Request Helpers

```@docs
query
body
multipart
MultipartFile
context
cookies
form
header
service
```

## URI & String Utilities

```@docs
parse_query
strip_query
format_headers
sanitize_header_value
url_decode
status_reason
```

## Middleware

```@docs
use!
cors
ratelimit
bearer
apikey
basicauth
logger
health
metrics
security
compress
AbstractMiddleware
FunctionMiddleware
Logger
Health
PrometheusMetrics
SecurityHeaders
Cors
Bearer
ApiKey
BasicAuth
RateLimit
Compress
```

## Server-Sent Events

```@docs
SSEWriter
emit
sse
```

## WebSocket

```@docs
Message
```

## Lifecycle

```@docs
onerror!
onstart!
onstop!
service!
background!
serve!
```

## Configuration

```@docs
ServerConfig
TLSConfig
```

## Extensibility

```@docs
AbstractRouter
SingleEndpoint
Endpoint
AbstractExecutor
SyncExecutor
AsyncExecutor
AbstractTransport
FakeTransport
TestClient
validate
ValidationError
```

## Content Formats

```@docs
Plain
Html
Json
Css
Js
Xml
Binary
encode
decode
```

## Module

```@docs
Mongoose.MongooseCore
```

## Errors

```@docs
HTTPError
error_status
RouteError
ServerError
BindError
```
