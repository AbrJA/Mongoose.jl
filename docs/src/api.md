# API Reference

```@meta
CurrentModule = Mongoose
```

> **Public vs extension API.** `using Mongoose` gives the application-facing
> surface (servers, requests, responses, middleware builders, helpers). The
> extension protocols below (router protocol, pipeline seam, format encoding,
> string utilities) are exported by `Mongoose.Kernel` and are reachable
> as `Mongoose.<name>` or via `import Mongoose: <name>` — both work without
> being re-exported at the top level, keeping the user namespace clean.

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
matchroute
hasroute
gethandler
getendpoint
Matched
NoMatch
WrongMethod
RouteResult
MethodMap
post!
patch!
options!
head!
```

## Request Processing

```@docs
process
RequestContext
terminalfor
errorresponse
runpipeline
asmiddleware
asmiddlewares
AbstractRequest
```

## Request & Response

```@docs
Request
Response
StreamResponse
Headers
asheaders
mergeheaders
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
parsequery
stripquery
formatheaders
urldecode
asstrings
statusreason
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
etag
AbstractMiddleware
FunctionMiddleware
Logger
Health
PrometheusMetrics
SecurityHeaders
Etag
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
ws_send_all
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
FakeExecutor
run!
AbstractTransport
FakeTransport
TestClient
close!
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
Mongoose.Kernel
```

## Errors

```@docs
HTTPError
errorstatus
RouteError
ServerError
BindError
```
