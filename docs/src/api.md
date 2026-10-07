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
AbstractServer
start!
shutdown!
isrunning
url
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
haswsroutes
getwsendpoint
Matched
NoMatch
MethodMismatch
RouteResult
MethodMap
post!
patch!
options!
head!
```

> `get!`, `put!`, and `delete!` are `Base` methods that Mongoose extends (the
> other verbs are Mongoose exports). All accept `(server_or_router, path,
> handler)` and the do-block form `get!(server, path) do req … end`.

## Request Processing

```@docs
process
RequestContext
getterminal
invokeendpoint
scopedmiddleware
errorresponse
runpipeline
asmiddleware
asmiddlewares
attach!
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
setcookie
```

## Request Helpers

```@docs
query
body
parsejson
parseform
parsemultipart
MultipartFile
parsecookies
context
header
service
services
withservices
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
Metrics
Security
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
broadcastws
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
stop!
FakeExecutor
run!
AbstractTransport
canws
cantls
canstream
FakeTransport
close!
validate
ValidationError
```

## Base integrations

Framework types implement the standard Base protocols where it makes sense:
`length`/`isempty` on `Router` and `App`, ordered dict-like views on
`Headers` (`pairs`, `keys`, `values`, plus `getindex`, `haskey`, `get`,
`iterate`, `push!`/`append!`/`delete!`), `==` on `Headers` and `Response`,
and terse one-line `show` for `Router`, `App`, `Request`, `Response`, and
`StreamResponse`.

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
