<p align="center">
    <img width="220px" src="logo.png"/>
</p>

<h1 align="center">Mongoose.jl</h1>

<p align="center">
    <strong>Production-ready HTTP & WebSocket framework for Julia</strong><br>
    Powered by the battle-tested <a href="https://github.com/cesanta/mongoose">Mongoose C library</a>
</p>

<p align="center">
    <a href="https://AbrJA.github.io/Mongoose.jl/dev"><img src="https://img.shields.io/badge/docs-dev-blue.svg" alt="Documentation"/></a>
    <a href="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml?query=branch%3Amain"><img src="https://github.com/AbrJA/Mongoose.jl/actions/workflows/CI.yml/badge.svg?branch=main" alt="Build Status"/></a>
    <img src="https://img.shields.io/badge/Julia-1.10+-purple.svg" alt="Julia 1.10+"/>
    <img src="https://img.shields.io/badge/license-GPL--2-green.svg" alt="License"/>
</p>

---

## ✨ Why Mongoose.jl?

- ⚡ **Fast** — precompiled cold start; `freeze!` compiles the route table so
  warm dispatch stays at ~100 ns (fixed routes) / ~400 ns (typed params) with
  minimal allocation.
- 🧪 **Testable without FFI** — `FakeTransport` drives the full pipeline in pure
  Julia: no ports, no C library, deterministic tests.
- 🧩 **Batteries included** — CORS, rate limiting, bearer/API-key/basic auth,
  gzip, ETag, security headers, structured logs, Prometheus metrics, health
  checks, static files.
- 📡 **Real-time built in** — WebSocket (including server-initiated push) and
  Server-Sent Events on the same port, with backpressure and graceful drain.
- 🔌 **Replaceable parts** — router, executor, and transport sit behind small
  protocols; the core has no FFI dependency and can be swapped or embedded.
- 🛡️ **Production defaults** — graceful shutdown on SIGINT **and SIGTERM**,
  request timeouts, header timeouts, connection caps, 503 backpressure, typed
  error handlers, dependency injection.

---

## 🚀 Quick Start

```julia
using Pkg; Pkg.add("Mongoose")
```

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
    json(parsejson(req); status=201)
end

start!(app; port=8080)
```

---

## 🧭 Routing

```julia
get!(app, "/items",        req -> ...)
post!(app, "/items",       req -> ...)
put!(app, "/items/:id",    (req, id) -> ...)
patch!(app, "/items/:id",  (req, id) -> ...)
delete!(app, "/items/:id", (req, id) -> ...)
route!(app, :get, "/search", req -> ...)
```

Typed path parameters use `:name::Type` and arrive as a typed tuple (invalid
values are 404s). Wildcards capture the rest of the path:

```julia
get!(app, "/users/:id::Int",       (req, id)   -> ...)   # id::Int
get!(app, "/price/:val::Float64",  (req, val)  -> ...)   # val::Float64
get!(app, "/posts/:slug",          (req, slug) -> ...)   # slug::String
get!(app, "/files/*path",          (req, path) -> ...)   # wildcard
```

**Groups** share a prefix and scoped middleware (composed as
`global → group → route` at dispatch time):

```julia
api = group("/api/v1", middleware=[
    ratelimit(max_requests=100, window_seconds=60),
    apikey("key-abc"; header_name="x-api-key"),
])

get!(api, "/users", list_users)
post!(api, "/users", create_user)

group!(api, "/admin", middleware=[bearer("admin-token")]) do admin
    delete!(admin, "/users/:id::Int", delete_user)
end

mount!(app, api)
```

**Compiled dispatch** — register everything, then `freeze!` to close and compile
the route table (later registration throws). The closed table is the foundation
for AOT builds; `juliac --trim` compatibility is still in progress (tracked in
`WORKLOG.md`):

```julia
freeze!(app)     # or freeze!(router) before App(router=router)
```

---

## 🧩 Middleware

Any callable `(req, next) → Response` is middleware — no subtyping needed.
Built-ins cover the common production stack:

```julia
use!(app, security())                                   # OWASP headers
use!(app, health())                                     # /healthz /readyz /livez
use!(app, metrics())                                    # Prometheus /metrics
use!(app, cors(origins="https://myapp.com"))            # CORS + preflight
use!(app, compress(min_size_bytes=1024))                # gzip
use!(app, etag())                                       # ETag + 304/412
use!(app, logger())                                     # access logs
use!(app, ratelimit(max_requests=100, window_seconds=60))
use!(app, bearer("secret"); paths=["/api"])             # path-scoped auth
use!(app, apikey(["key-abc", "key-xyz"]))
use!(app, basicauth("admin", ENV["ADMIN_PASSWORD"]))
serve!(app, "public"; uri_prefix="/static")             # C-level static files
```

Custom middleware — a closure or a small type:

```julia
use!(app) do req, next
    t = time()
    res = next()
    @info "$(req.method) $(req.uri)" status=res.status ms=round((time()-t)*1000; digits=1)
    res
end
```

---

## 📨 Request & Response

```julia
body(req)                  # raw body
parsejson(req)             # JSON → Dict/Array/...
parseform(req)             # urlencoded body → Dict
parsemultipart(req)        # multipart body → Dict/MultipartFile
parsecookies(req)          # Cookie header → Dict
parsequery(req)            # whole query Dict (query(req, k) for typed lookups)
validate(req, CreateUser)  # parse + coerce + validate into a struct
query(req, "page", 1)      # typed query param with default
header(req, "authorization")
context(req)               # per-request Dict{Symbol,Any}
```

```julia
json(Dict("ok" => true))                  # 200, application/json
json(data; status=201, headers=["X-H" => "v"])
text("Hello!")                            # text/plain
html("<h1>Hi</h1>")
redirect("/new"; status=301)
Response(Json, """{"raw":true}""")        # pre-serialized body
```

Errors can be thrown or handled by status/type:

```julia
throw(NotFoundError("user 7"))            # → 404 automatically

onerror!(app, 404) do req
    json(Dict("error" => "not found"); status=404)
end

onerror!(app, AccountGone) do req, e      # typed exception handler
    json(Dict("error" => "gone"); status=410)
end
```

---

## 📡 WebSocket & SSE

```julia
ws!(app, "/chat";
    allowed_origins = ["https://myapp.com"],   # optional
    on_open         = req -> true,             # false → 403
    on_message      = msg -> Message("Echo: $(msg.data)"),
    on_close        = () -> @info "disconnected",
)

# Server-initiated push to every client of a path (thread-safe, any task):
broadcastws(app, "/chat", "Server announcement")
```

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

---

## ⚙️ Configuration

```julia
app = App(;
    workers            = 4,          # 0 = sync (inline); N = worker pool
    queue_size         = 1024,       # pending requests before 503
    request_timeout_ms = 5_000,      # 0 = disabled (async mode)
    drain_timeout_ms   = 5_000,      # graceful shutdown budget
    max_body_bytes     = 1_048_576,
    header_timeout_ms  = 0,          # close conns that stall before a request
    max_connections    = 0,          # 0 = unlimited
    ws_max_frame_bytes = 1_048_576,
    ws_idle_timeout_ms = 0,          # 0 = disabled
    tls                = nothing,    # TLSConfig(cert=…, key=…)
)
```

Units are explicit in every name: `_ms` for timeouts, `_seconds` for protocol
durations, `_bytes` for sizes. Optional values are disabled with `nothing`.

HTTPS is native:

```julia
app = App(; tls = TLSConfig(cert="certs/server.crt", key="certs/server.key"))
start!(app; port=8443)
```

---

## 🛡️ Production

- **Graceful shutdown** — SIGINT and SIGTERM drain in-flight requests and SSE
  streams, run `onstop!` hooks, and stop workers (SIGTERM and normal exits go
  through Julia's `atexit` path; SIGINT is caught while `start!` blocks).
- **Backpressure** — the async executor bounds its queue and answers `503` when
  full; `max_connections` and `header_timeout_ms` protect against slow clients.
- **Observability** — `logger()` access logs, `metrics()` (request counters,
  latency histogram, and live gauges: connections, WS clients, streams,
  executor depth), and `health()` probes for Kubernetes.
- **Errors** — `onerror!` per status or per exception type; typed
  `HTTPError{status}` aliases map to responses automatically.
- **Introspection** — `isrunning(app)`, `url(app)`, `length(app)`,
  `matchroute(app, …)`, `hasroute(app, path)`.

```julia
onstart!(app) do; @info "starting"; connect_database!() end
onstop!(app)  do; @info "stopping"; close_database!() end

background!(app) do
    while true
        cleanup_expired_sessions!()
        sleep(60)
    end
end
```

Dependency injection is a typed NamedTuple; `withservices` gives type-stable
access inside the closure:

```julia
app = App(; services=(db=connect_to_database(), cache=RedisPool()))

get!(app, "/users") do req
    users = withservices(req) do svcs
        fetch_users(svcs.db)
    end
    json(users)
end
```

---

## 🧪 Testing Without a Server

`FakeTransport` runs the full pipeline — middleware, routing, serialization —
with no network and no FFI:

```julia
using Test, Mongoose

app = App()
get!(app, "/hello", req -> json(Dict("msg" => "hi")))
use!(app, cors())

client = FakeTransport(app)
resp = client(:get, "/hello")
@test resp.status == 200
@test contains(resp.body, "\"msg\"")
```

---

## 🔌 Pluggable Components

Each boundary is a replacement point: `App(router=my_router)`,
`App(workers=n)` chooses the executor, and `AbstractTransport` declares its
capabilities (`supportsws`, `supportstls`, `supportsstream`). Custom routers
implement `route!`/`matchroute`/`hasroute` and may carry their own endpoint
type via `invokeendpoint`. See the API reference for the exact contracts.

---

## 📚 Documentation & Examples

- **API reference**: [AbrJA.github.io/Mongoose.jl](https://AbrJA.github.io/Mongoose.jl/dev)
- **Examples**: [docs/src/examples.md](docs/src/examples.md) — REST, auth,
  streaming, WebSocket, middleware stacks, deployment patterns.
- **Changelog**: [CHANGELOG.md](CHANGELOG.md)

## License

Distributed under the GPL-2 License. See [`LICENSE`](LICENSE) for details.
