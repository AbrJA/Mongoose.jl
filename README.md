<p align="center">
    <img width="220px" src="logo.png"/>
</p>

<h1 align="center">Mongoose.jl</h1>

<p align="center">
    <strong>Production-ready HTTP & WebSocket framework for Julia</strong><br>
    Built on the battle-tested <a href="https://github.com/cesanta/mongoose">Mongoose C library</a>
</p>

<p align="center">
    <a href="https://AbrJA.github.io/Mongoose.jl/dev"><img src="https://img.shields.io/badge/docs-dev-blue.svg" alt="Documentation"/></a>
    <a href="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain"><img src="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main" alt="Build Status"/></a>
    <img src="https://img.shields.io/badge/Julia-1.10+-purple.svg" alt="Julia 1.10+"/>
    <img src="https://img.shields.io/badge/license-GPL--2-green.svg" alt="License"/>
</p>

---

## Why Mongoose.jl?

| Category | Highlights |
|---|---|
| **Performance** | Fast cold start (sub-100ms to first response, via precompilation) and warm paths under a microsecond per request with the frozen compiled dispatch. C-level static file serving with Range, ETag, gzip. |
| **Architecture** | Modular: `Router`, `Executor`, and `Transport` are replaceable components behind small protocols — plus a transport-agnostic core (`Mongoose.Kernel`) with **no FFI dependencies**, loadable and testable without the C library. Sync (`workers=0`) or bounded async worker pool. Backpressure and per-request timeouts. |
| **HTTPS/TLS** | Native TLS via `TLSConfig` — cert, key, CA as files, PEM strings, or raw bytes. |
| **Routing** | Exact-match `Dict` + ordered parametric patterns. Typed path parameters (`:id::Int`) delivered as typed tuples. Wildcards (`*path`). Route groups with scoped middleware as metadata. `freeze!` closes and compiles the route table for statically-typed dispatch (AOT/`--trim=safe` profile). |
| **WebSocket** | Same port as HTTP. Frame size limits. Idle timeout. Origin allowlist. Upgrade rejection. Ping/pong (RFC 6455). Server-initiated push to open clients (`broadcastws`). |
| **Middleware** | CORS, rate limiting, bearer/API key auth, structured logging, Prometheus metrics, health checks, security headers, GZip compression. Plain closures work as middleware. |
| **JSON** | Built-in JSON via JSON. `parsejson(req)` for parsing, `json(...)` for responses. Struct validation with `validate(req, T)`. |
| **Testing** | `FakeTransport` runs the whole pipeline with **no server and no FFI**. |
| **Production** | Graceful shutdown with drain on SIGINT **and SIGTERM**, plus `atexit`. 503 backpressure on overload. Header timeouts and connection caps. Custom *and* typed exception handlers. Background tasks. Dependency injection. |

---

## Installation

```julia
] add Mongoose
```

---

## Quick Start

```julia
using Mongoose

app = App(workers=4)

get!(app, "/") do req
    text("Hello from Mongoose.jl!")
end

get!(app, "/users/:id::Int") do req, id
    json(Dict("id" => id, "name" => "User $id"))
end

post!(app, "/echo") do req
    data = parsejson(req)                 # parses the JSON request body
    json(data; status=201)
end

start!(app; port=8080)
```

---

## Routing

### HTTP Methods

```julia
router = Router()

get!(router, "/items",       req -> ...)
post!(router, "/items",      req -> ...)
put!(router, "/items/:id",   (req, id) -> ...)
patch!(router, "/items/:id", (req, id) -> ...)
delete!(router, "/items/:id",(req, id) -> ...)
route!(router, :get, "/search", req -> ...)
```

HEAD is served only by an explicit `head!` route — there is **no auto-HEAD
fallback**, so a GET-only route answers `405` with an exact `Allow` header.
(The C backend has no native way to mirror a GET's `Content-Length` on HEAD,
so the library does not fake it.)

### Typed Path Parameters

Append `::Type` to a segment for automatic parsing. Invalid values return 404:

```julia
get!(router, "/users/:id::Int",      (req, id)   -> ...)  # id::Int
get!(router, "/price/:val::Float64", (req, val)  -> ...)  # val::Float64
get!(router, "/posts/:slug",         (req, slug) -> ...)  # slug::String
get!(router, "/files/*path",         (req, path) -> ...)  # wildcard catch-all
```

Parameters arrive as **typed tuples**: `/users/42` gives `(42,)` of type
`Tuple{Int}` — no `Any` boxing.

### Query Parameters

Use the `query()` helper for type-safe access with defaults:

```julia
get!(router, "/search", req -> begin
    q     = query(req, "q", "")       # String with default
    page  = query(req, "page", 1)     # auto-parses to Int
    limit = query(req, "limit", 20)   # auto-parses to Int
    text("Searching: $q, page $page, limit $limit")
end)
```

### Route Groups

Organize routes under a shared prefix with scoped middleware. Group middleware
is attached to the routes as **metadata** (not closures), so it is composed
with app-global middleware at dispatch time in the order `global → group → route`:

```julia
api = group("/api/v1", middleware=[
    ratelimit(max_requests=100, window_seconds=60),
    apikey(header_name="x-api-key", keys=Set(["key-abc"])),
])

get!(api, "/users",     list_users)
post!(api, "/users",    create_user)
get!(api, "/users/:id", get_user)

# Nested groups
group!(api, "/admin", middleware=[bearer(t -> t == "admin-token")]) do admin
    delete!(admin, "/users/:id::Int", delete_user)
end

mount!(app, api)
```

You can also scope middleware to a single route:

```julia
route!(router, :get, "/admin/panel", admin_panel; middleware=[bearer(t -> t == "admin-token")])
```

### Compiled Dispatch (`freeze!`)

For production startups, close the route table with `freeze!`. Everything
must be registered before you freeze — afterwards, `route!`/`ws!` throw
`RouteError`. This is the contract that makes an app amenable to AOT builds
(`juliac --trim=safe`): the table can be compiled once and pruned.

```julia
router = Router()
get!(router, "/users/:id::Int", get_user)
post!(router, "/users", create_user)
get!(router, "/files/*path", serve_file)

freeze!(router)                    # closes registration AND compiles dispatch

app = App(; router=router, workers=4)
start!(app; port=8080)
```

Freezing **compiles** the closed table (`CompiledDispatch`):

- Every route gets a pre-baked terminal — handler + scoped middleware fused
  once, with the handler's concrete type captured, so the call is statically
  typed.
- Parametric matching walks the raw path with byte indices — no per-request
  `Vector{String}` split, no registration-order re-scan overhead.
- The pipeline resolves via a pre-built terminal (no per-request closure or
  `[global; scoped]` concat allocation).

Dispatch semantics are unchanged (fixed-first, registration order, `"*"`
fallback, 405/404). On the warm path this is roughly 2–3× faster
than the generic dispatch with fewer allocations — e.g. a fixed route goes
from ~250ns to ~100ns per request, a two-parameter route from ~1.2µs to
~400ns.

---

## Request & Response

### Request Helpers

| Expression | Returns | Description |
|---|---|---|
| `body(req)` | `String` | Raw request body |
| `parsejson(req)` | `Any` | Parsed JSON body (Dict, Array, …) |
| `validate(req, T)` | `T` | Parse + validate JSON into a struct |
| `query(req, "key")` | `String \| nothing` | Query parameter |
| `query(req, "key", default)` | `typeof(default)` | Query param with auto-parsing |
| `multipart(req)` | `Dict{String, Union{String,MultipartFile}}` | Parse multipart/form-data |
| `form(req)` | `Dict{String,String}` | Parse `application/x-www-form-urlencoded` |
| `header(req, "name")` | `String \| nothing` | Case-insensitive header lookup |
| `cookies(req)` | `Dict{String,String}` | Parsed cookies |
| `context(req)` | `Dict{Symbol,Any}` | Lazily-allocated per-request context |
| `req.uri` | `String` | Full request URI |
| `req.method` | `Symbol` | `:get`, `:post`, etc. |

### Response Helpers

```julia
json(Dict("ok" => true))                    # 200, application/json
json(data; status=201)                      # custom status
json(data; headers=["X-Custom" => "val"])   # extra headers

text("Hello!")                              # 200, text/plain
html("<h1>Hi</h1>")                         # 200, text/html
redirect("/new-location")                   # 302
redirect("/new"; status=301)                # 301

# Low-level Response constructor
Response(Json, """{"raw": true}""")         # pre-serialized JSON string
Response(Plain, "hello"; status=200)
Response(200, "OK"; headers=["X-H" => "v"])
```

### Request Validation

Define any plain struct and `validate` will parse + coerce + check required
fields, throwing `ValidationError` on failure:

```julia
struct CreateUser
    name::String
    email::String
    age::Int
end

post!(app, "/users") do req
    user = validate(req, CreateUser)                 # → CreateUser
    json(Dict("name" => user.name, "age" => user.age));
end
```

### Content Formats

| Format | Content-Type |
|---|---|
| `Plain` | `text/plain; charset=utf-8` |
| `Html` | `text/html; charset=utf-8` |
| `Json` | `application/json; charset=utf-8` |
| `Xml` | `application/xml; charset=utf-8` |
| `Css` | `text/css; charset=utf-8` |
| `Js` | `application/javascript; charset=utf-8` |
| `Binary` | `application/octet-stream` |

**Framing note.** String/JSON responses go through the backend's native
framing (keep-alive safe). Raw binary bodies and streaming responses are
hand-framed on the wire, which bypasses the C backend's framing state — so
they always advertise `Connection: close` rather than risk a reused
connection wedge.

---

## App Configuration

```julia
app = App(;
    workers             = 4,          # Worker threads (0 = sync mode)
    queue_size          = 1024,       # Max pending requests (async)
    max_body_bytes      = 1_048_576,  # 1 MB max request body
    request_timeout_ms  = 5000,       # 5s per-request timeout (0 = disabled)
    drain_timeout_ms    = 5000,       # Graceful shutdown drain
    ws_max_frame_bytes  = 1_048_576,  # Max WebSocket frame size
    ws_idle_timeout_ms  = 60_000,     # WS idle timeout (0 = disabled)
    poll_timeout_ms     = 1,          # Mongoose poll interval
    header_timeout_ms   = 0,          # Close conns that stall before a request
    max_connections     = 0,          # Max open connections (0 = unlimited)
    router              = Router(),   # any AbstractRouter
    tls                 = nothing,    # TLSConfig for HTTPS
)
```

### Naming conventions

- **Types** are `TitleCase`; acronyms stay all-caps (`HTTPError`, `TLSConfig`,
  `SSEWriter`, `WSConn`, `WSEndpoint`). Content-format markers are the one
  exception (`Html`, `Json`, `Xml`, `Js`, `Css`) because they read as words.
- **Functions** are lowercase compounds with **no underscores** (`parsequery`,
  `formatheaders`, `mergeheaders`, `getwsendpoint`, `invokeendpoint`,
  `broadcastws`, `withservices`).
- **Middleware builders** are the lowercase name of the type they return:
  `cors()` → `Cors`, `metrics()` → `Metrics`, `security()` → `Security`,
  `compress()` → `Compress`, `etag()` → `Etag`.
- **Mutators** end in `!` (`route!`, `use!`, `shutdown!`, `freeze!`).
- **Predicates** are `is*`/`has*` (`isfrozen`, `isrunning`, `hasroute`,
  `haspending`).
- **Teardown verbs by scope**: server `start!`/`shutdown!`; executor
  `start!`/`stop!`; transport/streams `close!`.
- **Capabilities** are traits: `supportsws`/`supportstls`/`supportsstream`
  on transports, `haswsroutes`/`getwsendpoint` on routers.
- **`get!`/`put!`/`delete!`** are `Base` methods Mongoose extends (the other
  HTTP verbs are Mongoose exports) — see the API reference.
- Documented spec-name exceptions: `Cookie(; max_age=…)` mirrors the
  `Set-Cookie` attribute, and FFI structs keep their `Mg*` prefix.

### Unit conventions

Every quantity carries its unit — as a suffix on Python-style kwargs and
builder arguments, and as values in the documented tables:

| Kind | Suffix | Examples |
|------|--------|----------|
| Timeouts / waits | `_ms` (milliseconds) | `request_timeout_ms`, `drain_timeout_ms`, `ws_idle_timeout_ms`, `poll_timeout_ms`, `logger(threshold_ms=…)`, `emit(…; retry_ms=…)` |
| Protocol durations in seconds | `_seconds` | `ratelimit(window_seconds=…)`, `cors(max_age_seconds=…)`, `security(hsts_max_age_seconds=…)` |
| Body / frame / compression sizes | `_bytes` | `max_body_bytes`, `ws_max_frame_bytes`, `compress(min_size_bytes=…)` |
| Standard protocol parameters keep their spec names | — | `Cookie(…; max_age=…)` is `Max-Age` in seconds; HTTP header names (`Retry-After`, …) are RFC-defined |

"Off" is uniform: pass `nothing` to omit an optional header/value
(e.g. `security(csp=nothing)`, `security(hsts_max_age_seconds=nothing)`);
`0` disables timeouts where documented.

### HTTPS / TLS

```julia
app = App(;
    router = router,
    tls = TLSConfig(
        cert = "certs/server.crt",
        key  = "certs/server.key",
    ),
)
start!(app; port=8443)
```

### Custom Error Responses

```julia
onerror!(app, 404) do req          # dynamic handler: (req) → Response
    json(Dict("error" => "Not found", "path" => req.uri); status=404)
end

onerror!(app, 500, json(Dict("error" => "Internal Server Error"); status=500))
onerror!(app, 413, json(Dict("error" => "Request body too large"); status=413))
```

### Typed Exception Handlers

Route handler/middleware exceptions by *type*:

```julia
struct AccountGone <: Exception end

onerror!(app, AccountGone) do req, e
    json(Dict("error" => "not found"); status=404)
end
```

---

## Middleware

Middleware runs in registration order: app-global first, then group/route-scoped.
Each middleware can inspect/modify the request, short-circuit, or call `next()`.

```julia
app = App(; router=router, workers=4)

# Security headers (OWASP best practices)
use!(app, security())

# Health checks (Kubernetes-ready: /healthz, /readyz, /livez)
use!(app, health())

# Prometheus metrics at GET /metrics
use!(app, metrics())

# CORS
use!(app, cors(origins="https://myapp.com", allow_methods="GET, POST, PUT, DELETE"))

# GZip compression (responses > 1KB)
use!(app, compress(min_size_bytes=1024))

# Structured JSON access logs
use!(app, logger())

# Rate limiting — 100 requests per 60s per client IP
use!(app, ratelimit(max_requests=100, window_seconds=60))

# Bearer token auth — scoped to /api routes only
use!(app, bearer(token -> token == ENV["API_TOKEN"]); paths=["/api"])

# API key auth
use!(app, apikey(header_name="x-api-key", keys=Set(["key-abc", "key-xyz"])))

# HTTP Basic auth
use!(app, basicauth("admin", ENV["ADMIN_PASSWORD"]))

# Rate limiting (private-keyed; trust proxy headers only behind your proxy)
use!(app, ratelimit(max_requests=100, window_seconds=60; trust_proxies=false))
use!(app, ratelimit(max_requests=100, key_fn=req -> get(req.headers, "x-api-key", "")))

# CORS: allowlist + credentials, preflight-validated
use!(app, cors(origins=["https://myapp.com"], allow_credentials=true))

# Static file serving (C-level, with Range/ETag/gzip)
serve!(app, "public"; uri_prefix="/static")
```

### Custom Middleware

**No subtyping required.** Any callable `(req, next) → Response` is a
middleware — plain closures work out of the box:

```julia
use!(app) do req, next
    t = time()
    res = next()
    @info "$(req.method) $(req.uri)" status=res.status ms=round((time()-t)*1000; digits=1)
    res
end
```

For configurable/named middleware, subtype `AbstractMiddleware` (or just return
a closure from a factory):

```julia
struct RequestTimer <: Mongoose.AbstractMiddleware end

function (::RequestTimer)(req::Request, next::Function)
    t = time()
    res = next()
    @info "$(req.method) $(req.uri)" ms=round((time()-t)*1000; digits=1)
    return res
end

use!(app, RequestTimer())
```

---

## WebSocket

```julia
ws!(app, "/chat";
    allowed_origins = ["https://myapp.com"],  # optional Origin allowlist
    on_open = (req::Request) -> begin
        # Return false to reject the upgrade with 403
        auth = get(req.headers, "authorization", nothing)
        auth === nothing && return false
        true
    end,
    on_message = (msg::Message) -> Message("Echo: $(msg.data)"),
    on_close = () -> @info "WS disconnected"
)
```

| Callback | Signature | Notes |
|---|---|---|
| `allowed_origins` | `Vector{String}` | Only these Origins may upgrade (empty = allow any). Optional. |
| `on_open` | `(req) → Any` | Return `false` to reject with 403. Optional. |
| `on_message` | `(msg) → Message \| nothing` | Called per frame. Return `nothing` for no reply. |
| `on_close` | `() → Any` | Connection already gone. Optional. |

#### Server-initiated push (`broadcastws`)

Send a frame to every open client of a path — from any task — via the same
thread-safe reply queue the worker pool uses:

```julia
ws!(app, "/stock"; on_message = msg -> Message("pong"))

# broadcast to everyone currently connected to /stock (async executors)
broadcastws(app, "/stock", JSON.json(Dict("event" => "low", "sku" => "SHOP-MUG-6")))
```

Frames are sent on the poll/callback thread, so this is safe to call from
background tasks, event relays, or request handlers. Stale connections are
dropped naturally. (The Shop API example uses it to push every stock-change
event onto its WebSocket inventory console.)

---

## Server-Sent Events (SSE)

Push real-time events to clients:

```julia
get!(app, "/events") do req
    sse(req) do writer
        for i in 1:10
            emit(writer; data="Tick $i", event="update", id=string(i))
            sleep(1)
        end
    end
end
```

`sse()` returns a `StreamResponse` with correct SSE headers. `emit()` formats
each event per the W3C EventSource spec.

---

## Dependency Injection

Services are stored as a typed NamedTuple, registrable at construction or via
`service!`:

```julia
app = App(; router=router, workers=4, services=(db=connect_to_database(), cache=RedisPool()))

# Or incrementally:
service!(app, :db, connect_to_database())

# Type-stable access: the closure receives the concrete NamedTuple.
get!(app, "/users") do req
    users = withservices(req) do svcs
        fetch_users(svcs.db)        # svcs.db :: DBPool
    end
    json(users)
end

# Convenient lookups (dynamically typed — they read through the request context):
service(req, :db)                   # → Any
service(req, Val(:db))              # → Any (no name re-parse)
service(req, :db, DBPool)           # → DBPool or throws
services(req)                       # → the whole NamedTuple
```

---

## Background Tasks & Lifecycle Hooks

```julia
onstart!(app) do
    @info "Server started"
    seed_database!()
end

onstop!(app) do
    @info "Closing connections..."
    close_database!()
end

background!(app) do
    while true
        cleanup_expired_sessions!()
        sleep(60)
    end
end
```

---

## Cookies

```julia
get!(app, "/profile") do req
    session = get(cookies(req), "session", nothing)
    session === nothing && return text("Not logged in"; status=401)
    text("Hello!")
end

post!(app, "/login") do req
    c = Cookie("session", "abc123";
        httponly = true,
        secure   = true,
        max_age  = 3600,
        samesite = :strict,
    )
    text("Logged in"; headers=["Set-Cookie" => setcookie(c)])
end
```

---

## Pluggable Components

Each boundary is a replacement point, so you can swap parts without rewriting
your app.

### Router

Implement `AbstractRouter` and hand it to `App(router=my_router)`. The
required protocol:

| Function | Role |
|---|---|
| `route!(r, method, path, handler; middleware, metadata)` | register an `Endpoint` |
| `matchroute(r, method, path)` | return a `RouteResult` (`Matched`/`NoMatch`/`NotAllowed`) |
| `gethandler(match, method)` | handler for that method, or `nothing` |
| `getendpoint(match, method)` | the route's `Endpoint`, or `nothing` |
| `hasroute(r, path)` | path owned by a concrete route (catch-all excluded) — static-serving shadow check |

Optional capabilities (`length(router)`, `haswsroutes`, `getwsendpoint`, `ws!`,
`freeze!`, `isfrozen`) have safe "not supported" defaults. Missing required
methods fail loudly via fallback `MethodError`s. The default `Router` also
implements the optional compiled-dispatch capability `terminalfor(r, req)`:
after `freeze!` it returns a pre-built terminal (with scoped middleware fused)
so the pipeline skips per-request dispatch allocations —
other routers simply fall back to the generic path.

### Executor

`SyncExecutor` (inline) and `AsyncExecutor` (bound worker pool) implement the
`submit!/start!/stop!/haspending` contract. `App(workers=n)` chooses between
them; a custom executor can carry its own concurrency policy.

### Transport

`AbstractTransport` declares capabilities via trait functions
(`supportsws`, `supportstls`, `supportsstream`). The C transport
(`transport/mongoose`) wraps the Mongoose C library; `FakeTransport` runs
everything in pure Julia — that is what `FakeTransport` is.

---

## Testing

Use `FakeTransport` for fast, network-free testing:

```julia
using Test, Mongoose

app = App()
get!(app, "/hello", req -> json(Dict("msg" => "hi")))
use!(app, cors())

client = FakeTransport(app)   # or FakeTransport(app)

# Make requests without starting a server — no ports, no Mongoose_jll
resp = client(:get, "/hello")
@test resp.status == 200
@test contains(resp.body, "\"msg\"")

resp = client(:post, "/users";
    body = """{"name": "Alice"}""",
    headers = ["Content-Type" => "application/json"],
    query = Dict("notify" => "true"),
)
@test resp.status == 201
```

---

## Full Example

```julia
using Mongoose

app = App(; workers=4, request_timeout_ms=10_000, ws_idle_timeout_ms=60_000)

# Health
get!(app, "/health") do req; text("ok") end

# REST API
get!(app, "/api/users/:id::Int") do req, id
    json(Dict("id" => id, "name" => "User $id"))
end

post!(app, "/api/users") do req
    data = parsejson(req)
    json(Dict("created" => data["name"]); status=201)
end

# WebSocket with origin allowlist
ws!(app, "/ws";
    allowed_origins = ["https://example.com"],
    on_message = msg -> Message(Mongoose.encode(Json, Dict("ack" => true))),
    on_open = req -> @info("WS connected"),
    on_close = () -> @info("WS disconnected"),
)

# SSE
get!(app, "/events") do req
    sse(req) do writer
        for i in 1:5
            emit(writer; data="tick $i", event="heartbeat", id=string(i))
            sleep(1)
        end
    end
end

use!(app, security())
use!(app, health())
use!(app, metrics())
use!(app, cors(origins="*"))
use!(app, compress(min_size_bytes=1024))
use!(app, logger())
use!(app, bearer(t -> t == "secret"); paths=["/api"])

serve!(app, "public"; uri_prefix="/static")

onerror!(app, 500, json(Dict("error" => "Internal error"); status=500))
service!(app, :version, "1.0.0")

start!(app; port=8080)
```

---

## Deployment

- **Direct HTTPS**: Use `TLSConfig` for native TLS termination.
- **Reverse Proxy**: Place behind nginx/Caddy/Traefik for TLS + load balancing.
- **Docker**: Minimal base image — only needs the Julia runtime and compiled sysimage.
- **Kubernetes**: Built-in `/healthz`, `/readyz`, `/livez` endpoints via `health()` middleware.

---

## Documentation

Full API reference and examples: **[AbrJA.github.io/Mongoose.jl](https://AbrJA.github.io/Mongoose.jl/dev)**

## License

Distributed under the GPL-2 License. See [`LICENSE`](LICENSE) for details.