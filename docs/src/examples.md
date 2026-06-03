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

JSON is built-in via JSON3 — no setup required:

```julia
using Mongoose

router = Router()

# Return JSON responses using json() helper
route!(router, :get, "/users/:id::Int", (req, id) ->
    json(Dict("id" => id, "name" => "User $id", "active" => true))
)

# Parse JSON request body with body()
route!(router, :post, "/users", req -> begin
    data = body(req)  # returns Dict/Array from JSON
    json(Dict("created" => data["name"]); status=201)
end)

# Typed deserialization with StructTypes
using StructTypes

struct CreateUser
    name::String
    email::String
    age::Int
end
StructTypes.StructType(::Type{CreateUser}) = StructTypes.Struct()

route!(router, :post, "/users/typed", req -> begin
    user = body(req, CreateUser)  # deserializes into struct
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
    files = multipart(req)
    isempty(files) && return json(Dict("error" => "No files"); status=400)

    results = map(files) do f
        Dict("filename" => f.filename, "size" => length(f.data), "type" => f.content_type)
    end

    json(Dict("files" => results, "count" => length(files)); status=201)
end)

app = App(; router=router, workers=4, max_body=10_000_000)  # 10MB limit
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
use!(app, compress(min_size=1024))                           # GZip compression
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
    data = body(req)
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
    ws.onopen = () => ws.send("hello");
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

app = App(; router=router, workers=4, ws_idle_timeout=60_000)
start!(app; port=8080)
```

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
    bake(json(Dict("logged_in" => true)), c)
end)

route!(router, :get, "/profile", req -> begin
    jar = cookies(req)
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

# Dynamic error handler
onerror!(app, 404) do req, status
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
    db = inject(req, :db)
    name = get(db.users, id, nothing)
    name === nothing && return json(Dict("error" => "not found"); status=404)
    json(Dict("id" => id, "name" => name))
end)

app = App(; router=router, workers=4)
provide!(app, :db, FakeDB(Dict(1 => "Alice", 2 => "Bob")))

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
use!(app, compress(min_size=1024))

start!(app; port=8080)
```

## Testing with TestClient

```julia
using Test, Mongoose

# Setup
router = Router()
route!(router, :get, "/hello", req -> json(Dict("msg" => "hi")))
route!(router, :post, "/echo", req -> begin
    data = body(req)
    json(data; status=201)
end)

app = App(; router=router)
use!(app, cors())

client = TestClient(app)

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

## Production Configuration

```julia
using Mongoose

router = Router()
# ... define routes ...

app = App(;
    router          = router,
    workers         = parse(Int, get(ENV, "WORKERS", "4")),
    queuesize       = 2048,
    max_body        = 4_000_000,       # 4MB
    request_timeout = 30_000,          # 30s
    drain_timeout   = 10_000,          # 10s graceful shutdown
    ws_idle_timeout = 120_000,         # 2min WS idle
)

# Full middleware stack
use!(app, security())
use!(app, health(ready_check = () -> true))
use!(app, metrics())
use!(app, cors(origins=get(ENV, "CORS_ORIGINS", "*")))
use!(app, compress(min_size=1024))
use!(app, logger())

# Error responses
onerror!(app, 500, json(Dict("error" => "Internal error"); status=500))
onerror!(app, 413, json(Dict("error" => "Too large"); status=413))
onerror!(app, 503, json(Dict("error" => "Overloaded"); status=503))

# Services
provide!(app, :env, get(ENV, "APP_ENV", "production"))

# Static assets
serve!(app, "public"; uri_prefix="/static")

start!(app; host="0.0.0.0", port=parse(Int, get(ENV, "PORT", "8080")))
```
