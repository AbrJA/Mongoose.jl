# Examples

## Hello World

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> text("Hello, World!"))

app = App(; router=router)
start!(app; port=8080)
```

## HTTPS Server (TLS)

```julia
using Mongoose

router = Router()
route!(router, :get, "/secure", req -> text("secure ok"))

app = App(; router=router, tls=TLSConfig(cert="certs/server.crt", key="certs/server.key"))
start!(app; port=8443)
```

## REST API with Typed Parameters

```julia
using Mongoose

router = Router()

# String parameter (default)
route!(router, :get, "/greet/:name", (req, name) -> text("Hello, $name!"))

# Typed integer — /users/abc returns 404 automatically
route!(router, :get, "/users/:id::Int", (req, id) ->
    json(Dict("id" => id, "type" => string(typeof(id))))
)

# Float parameter
route!(router, :get, "/price/:amount::Float64", (req, amount) -> begin
    tax = amount * 0.16
    json(Dict("amount" => amount, "tax" => tax))
end)

# Wildcard catch-all
route!(router, :get, "/files/*path", (req, path) ->
    text("Requested: $path")
)

app = App(; router=router, workers=4)
start!(app; port=8080)
```

## Frozen Router (Compiled Dispatch)

Once all routes are registered, `freeze!(router)` closes the table and
compiles it: each route's terminal (handler + scoped middleware) is pre-baked
with the handler's concrete type captured, and parametric matching walks the
raw path with byte indices — no per-request path split, no closure/concat
allocation. Dispatch semantics stay identical; only registration is locked.

```julia
using Mongoose

router = Router()

get!(router, "/users/:id::Int", (req, id) -> json(Dict("id" => id)))
post!(router, "/users", req -> json(Dict("created" => true); status=201))
get!(router, "/files/*path", (req, path) -> text("Requested: $path"))

freeze!(router)   # route!/ws! throw RouteError from here on

app = App(; router=router, workers=4)
start!(app; port=8080)
```

Freezing also provides the closed-table guarantee AOT builds need: with no
runtime registration, the route table can be compiled once and pruned. Note
that `juliac --trim` compatibility is **not complete yet** — the trim
verifier still finds dynamic dispatch in startup/registration (see
`WORKLOG.md`, "AOT / trimming readiness"). Call `freeze!` after the last
registration and before starting the app.

## Query Parameters

Use the `query()` helper for type-safe access with automatic parsing:

```julia
using Mongoose

router = Router()

route!(router, :get, "/search", req -> begin
    q     = query(req, "q", "")       # String default
    page  = query(req, "page", 1)     # Auto-parsed to Int
    limit = query(req, "limit", 10)   # Auto-parsed to Int
    active = query(req, "active", true)  # Auto-parsed to Bool

    json(Dict("query" => q, "page" => page, "limit" => limit, "active" => active))
end)

app = App(; router=router, workers=4)
start!(app; port=8080)
```

## JSON Request and Response

JSON is built-in via JSON — no setup required:

```julia
using Mongoose

router = Router()

# Return JSON responses using json() helper
route!(router, :get, "/users/:id::Int", (req, id) ->
    json(Dict("id" => id, "name" => "User $id", "active" => true))
)

# Parse JSON request body with json()
route!(router, :post, "/users", req -> begin
    data = parsejson(req)  # returns Dict/Array from JSON
    json(Dict("created" => data["name"]); status=201)
end)

# Typed request validation into a struct
struct CreateUser
    name::String
    email::String
    age::Int
end

route!(router, :post, "/users/typed", req -> begin
    user = validate(req, CreateUser)  # parses + validates; throws ValidationError
    json(Dict("name" => user.name, "email" => user.email))
end)

app = App(; router=router, workers=4)
start!(app; port=8080)
```

## Multipart File Upload

```julia
using Mongoose

router = Router()

route!(router, :post, "/upload", req -> begin
    parts = parsemultipart(req)  # Dict{String, Union{String, MultipartFile}}
    isempty(parts) && return json(Dict("error" => "No files"); status=400)

    for (name, value) in parts
        # value is a String (form field) or MultipartFile (uploaded file)
    end

    file = parts["avatar"]::MultipartFile
    json(Dict("files" => [file.filename], "size" => length(file.data)); status=201)
end)

app = App(; router=router, workers=4, max_body_bytes=10_000_000)  # 10MB limit
start!(app; port=8080)
```

## Middleware Stack

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> json(Dict("status" => "ok")))
route!(router, :get, "/api/data", req -> json(Dict("data" => [1,2,3])))

app = App(; router=router, workers=4)

# Middleware runs in registration order
use!(app, security())                                        # Security headers
use!(app, health())                                          # /healthz, /readyz, /livez
use!(app, metrics())                                         # GET /metrics
use!(app, cors(origins="*"))                                 # CORS headers
use!(app, compress(min_size_bytes=1024))                           # GZip compression
use!(app, logger())                                          # Access logs
use!(app, ratelimit(max_requests=100, window_seconds=60))    # Rate limiting
use!(app, bearer(t -> t == "secret"); paths=["/api"])        # Auth on /api only

start!(app; port=8080)
```

## Custom Middleware

```julia
using Mongoose

struct RequestTimer <: Mongoose.AbstractMiddleware end

function (::RequestTimer)(req::Request, next::Function)
    t = time()
    res = next()
    elapsed = round((time() - t) * 1000, digits=1)
    @info "$(req.method) $(req.uri)" status=res.status ms=elapsed
    return res
end

router = Router()
route!(router, :get, "/", req -> text("hello"))

app = App(; router=router, workers=4)
use!(app, RequestTimer())
start!(app; port=8080)
```

## Route Groups

```julia
using Mongoose

router = Router()

# Public routes
route!(router, :get, "/", req -> json(Dict("msg" => "welcome")))

# API group with scoped middleware
api = group("/api/v1", middleware=[
    ratelimit(max_requests=100, window_seconds=60),
    apikey(header_name="x-api-key", keys=Set(["my-key"])),
])

route!(api, :get, "/users", req -> json(Dict("users" => [])))
route!(api, :post, "/users", req -> begin
    data = parsejson(req)
    json(Dict("created" => data["name"]); status=201)
end)
route!(api, :get, "/users/:id::Int", (req, id) -> json(Dict("id" => id)))

# Nested admin group
group!(api, "/admin", middleware=[bearer(t -> t == "admin-secret")]) do admin
    route!(admin, :delete, "/users/:id::Int", (req, id) ->
        json(Dict("deleted" => id))
    )
end

mount!(router, api)

app = App(; router=router, workers=4)
start!(app; port=8080)
```

## WebSocket

```julia
using Mongoose

router = Router()

route!(router, :get, "/", req -> html("""
    <script>
    const ws = new WebSocket("ws://localhost:8080/ws");
    ws.onmessage = e => console.log(e.data);
    ws.on_open = () => ws.send("hello");
    </script>
    <p>Check console</p>
"""))

ws!(router, "/ws";
    on_open = req -> begin
        auth = get(req.headers, "authorization", nothing)
        # Return false to reject with 403
        @info "WS connected" uri=req.uri
        true
    end,
    on_message = msg -> Message("Echo: $(msg.data)"),
    on_close = () -> @info "WS disconnected"
)

app = App(; router=router, workers=4, ws_idle_timeout_ms=60_000)
start!(app; port=8080)
```

## WebSocket Server Push (`broadcastws`)

WebSockets can also be *pushed* to: send a frame to every open client of a
path from any task (background housekeeping, event relays, request handlers).
Frames route through the same thread-safe reply queue the worker pool uses
and are actually sent on the poll thread, so no C connection is ever touched
from another thread.

```julia
using Mongoose
import JSON

router = Router()

# Clients subscribe to stock updates
ws!(router, "/stock";
    on_message = msg -> Message("pong: $(msg.data)"),
)

app = App(; router=router, workers=4)

# Broadcast a stock event to everyone currently connected to /stock
broadcastws(app, "/stock", JSON.json(Dict("event" => "low", "sku" => "SHOP-MUG-6")))

start!(app; port=8080)
```

Requires an async executor (`workers > 0`); stale/closed connections are
dropped silently.

## Server-Sent Events (SSE)

```julia
using Mongoose

router = Router()

route!(router, :get, "/events", req ->
    sse(req) do writer
        for i in 1:10
            emit(writer; data="Tick $i", event="heartbeat", id=string(i))
            sleep(1)
        end
        emit(writer; data="done", event="close")
    end
)

route!(router, :get, "/", req -> html("""
    <script>
    const es = new EventSource("/events");
    es.addEventListener("heartbeat", e => console.log(e.data));
    es.addEventListener("close", e => { console.log("done"); es.close(); });
    </script>
    <p>Check console for SSE events</p>
"""))

app = App(; router=router, workers=4)
start!(app; port=8080)
```

## Static File Serving

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> redirect("/static/index.html"))

app = App(; router=router, workers=4)

# Serve files from "public/" directory at /static/* prefix
# Supports Range requests, ETag, and gzip (handled at C level)
serve!(app, "public"; uri_prefix="/static")

start!(app; port=8080)
```

## Cookies

```julia
using Mongoose

router = Router()

route!(router, :post, "/login", req -> begin
    c = Cookie("session", "abc123";
        httponly = true,
        secure   = true,
        max_age  = 3600,
        samesite = :strict,
    )
    setcookie(c)  # serialize to a Set-Cookie header value; add it as a response header:
    json(Dict("logged_in" => true); headers=["Set-Cookie" => setcookie(c)])
end)

route!(router, :get, "/profile", req -> begin
    jar = parsecookies(req)
    session = get(jar, "session", nothing)
    session === nothing && return json(Dict("error" => "unauthorized"); status=401)
    json(Dict("session" => session))
end)

app = App(; router=router, workers=4)
start!(app; port=8080)
```

## Custom Error Responses

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> json(Dict("ok" => true)))

app = App(; router=router, workers=4)

# Static error responses
onerror!(app, 500, json(Dict("error" => "Internal Server Error"); status=500))
onerror!(app, 413, json(Dict("error" => "Payload too large"); status=413))

# Dynamic error handler (handler receives the request)
onerror!(app, 404) do req
    json(Dict("error" => "Not found", "path" => req.uri); status=404)
end

start!(app; port=8080)
```

## Dependency Injection

```julia
using Mongoose

# Example: share a database connection
struct FakeDB
    users::Dict{Int,String}
end

router = Router()

route!(router, :get, "/users/:id::Int", (req, id) -> begin
    db = withservices(req) do svcs
        svcs.db                       # concrete type → type-stable
    end
    name = get(db.users, id, nothing)
    name === nothing && return json(Dict("error" => "not found"); status=404)
    json(Dict("id" => id, "name" => name))
end)

app = App(; router=router, workers=4)
service!(app, :db, FakeDB(Dict(1 => "Alice", 2 => "Bob")))

start!(app; port=8080)
```

## Background Tasks & Lifecycle Hooks

```julia
using Mongoose

router = Router()
route!(router, :get, "/", req -> text("running"))

app = App(; router=router, workers=4)

onstart!(app) do
    @info "Server started, seeding data..."
end

onstop!(app) do
    @info "Graceful shutdown complete"
end

background!(app) do
    while true
        @info "Background tick" time=time()
        sleep(30)
    end
end

start!(app; port=8080)
```

## GZip Compression

```julia
using Mongoose

router = Router()

# Large response that benefits from compression
route!(router, :get, "/data", req -> begin
    large_data = Dict("items" => [Dict("id" => i, "value" => "x"^100) for i in 1:100])
    json(large_data)
end)

app = App(; router=router, workers=4)

# Compress responses larger than 1KB when client accepts gzip
use!(app, compress(min_size_bytes=1024))

start!(app; port=8080)
```

## Testing with FakeTransport

`FakeTransport` is the FFI-free reference transport:
it dispatches requests through the full pipeline with **no server and no
`Mongoose_jll`**, so tests never bind a port.

```julia
using Test, Mongoose

# Setup
router = Router()
route!(router, :get, "/hello", req -> json(Dict("msg" => "hi")))
route!(router, :post, "/echo", req -> begin
    data = parsejson(req)
    json(data; status=201)
end)

app = App(; router=router)
use!(app, cors())

client = FakeTransport(app)   # or: FakeTransport(app)

# Test GET
resp = client(:get, "/hello")
@test resp.status == 200
@test contains(resp.body, "\"msg\"")

# Test POST with JSON body
resp = client(:post, "/echo";
    body = """{"name": "Alice"}""",
    headers = ["Content-Type" => "application/json"],
)
@test resp.status == 201
@test contains(resp.body, "Alice")

# Test with query parameters
resp = client(:get, "/hello"; query=Dict("foo" => "bar"))
@test resp.status == 200
```

For deterministic async tests, `FakeExecutor` mirrors the `AsyncExecutor`
contract (queued `submit!`, `haspending`, `start!`/`stop!`) but never spawns
workers: jobs run only when the test calls `run!`, inline in submission
order — no threads, no sleeps.

```julia
fe = FakeExecutor()
@test submit!(fe, () -> "first") == true   # enqueued, not run
@test haspending(fe)
@test run!(fe) == ["first"]                # FIFO, inline
@test !haspending(fe)
```

## Production Configuration

```julia
using Mongoose

router = Router()
# ... define routes ...

app = App(;
    router          = router,
    workers         = parse(Int, get(ENV, "WORKERS", "4")),
    queue_size       = 2048,
    max_body_bytes        = 4_000_000,       # 4MB
    request_timeout_ms = 30_000,          # 30s
    drain_timeout_ms   = 10_000,          # 10s graceful shutdown
    ws_idle_timeout_ms = 120_000,         # 2min WS idle
    header_timeout_ms  = 10_000,          # close conns that stall before headers
    body_timeout_ms    = 30_000,          # max time to receive a request body
    max_header_bytes   = 64 * 1024,       # request-header cap
    max_connections    = 10_000,          # refuse beyond this many open conns
)

# Full middleware stack
use!(app, security())
use!(app, health(ready_check = () -> true))
use!(app, metrics())
use!(app, cors(origins=get(ENV, "CORS_ORIGINS", "*")))
use!(app, compress(min_size_bytes=1024))
use!(app, logger())

# Error responses
onerror!(app, 500, json(Dict("error" => "Internal error"); status=500))
onerror!(app, 413, json(Dict("error" => "Too large"); status=413))
onerror!(app, 503, json(Dict("error" => "Overloaded"); status=503))

# Services
service!(app, :env, get(ENV, "APP_ENV", "production"))

# Static assets
serve!(app, "public"; uri_prefix="/static")

start!(app; host="0.0.0.0", port=parse(Int, get(ENV, "PORT", "8080")))
```
