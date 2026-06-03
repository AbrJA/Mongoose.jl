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
RouteGroup
group
mount!
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
ctx!
cookies
form
header
inject
```

## Middleware

```@docs
use!
cors
ratelimit
bearer
apikey
logger
health
metrics
security
compress
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

## Configuration

```@docs
TLSConfig
```

## Lifecycle

```@docs
onerror!
onstart!
onstop!
provide!
background!
serve!
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
```

## Errors

```@docs
RouteError
ServerError
BindError
```
