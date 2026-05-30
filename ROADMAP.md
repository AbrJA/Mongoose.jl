# Mongoose.jl — Development Roadmap

> Breaking changes accepted. Simplicity over backward compatibility.

---

## Phase 1: Foundation Cleanup (v0.4)
**Goal:** Clean, testable, well-named codebase. No new features — only structural fixes.

### 1.1 Remove Dead Code & Consolidate Router
- [ ] Delete `src/router/dynamic.jl` (superseded by `trie.jl`)
- [ ] Audit all includes in `Mongoose.jl` for orphan files
- [ ] Remove `src/core/` directory if fully migrated to `src/server/`

### 1.2 Structured Response Headers
**Breaking change:** Replace raw header string with typed vector.

```julia
# Before (dangerous, not composable):
Response(200, "X-Custom: val\r\nX-Other: val2\r\n", "body")

# After (safe, composable):
struct Response
    status::Int
    headers::Vector{Pair{String,String}}
    body::Union{String, Vector{UInt8}}
    format::Type{<:AbstractFormat}
end

Response(Json, data; status=200, headers=["X-Custom" => "val"])
```

Changes required:
- [ ] Redefine `Response` struct with `Vector{Pair{String,String}}` headers
- [ ] Update `send_http_response!` to format headers from vector
- [ ] Update all middleware that inspects/modifies response headers
- [ ] Update `Response(format, body; kwargs...)` constructors
- [ ] Remove raw `(status, header_string, body)` constructor
- [ ] Update X-Request-Id injection to use structured headers
- [ ] Update all tests

### 1.3 Naming Convention Standardization
Julia conventions: no `_` prefix for private functions, `!` for mutation, `snake_case`.

| Current | Proposed | File |
|---------|----------|------|
| `_build_chain` | `build_chain` | middleware/pipeline.jl |
| `_is_pem` | `is_pem_string` | server/lifecycle.jl |
| `_is_path` | `is_file_path` | server/lifecycle.jl |
| `_PORT_COUNTER` | `PORT_COUNTER` | test/helpers.jl |
| `_RATE_LIMIT_SHARDS` | `RATE_LIMIT_SHARDS` | middleware/ratelimit.jl |
| `_RateShard` | `RateShard` | middleware/ratelimit.jl |
| `_print_info/warn/error` | `log_info/warn/error` | util/log.jl |
| `_escape` | `escape_json_value` | middleware/logger.jl |
| `_send_binary_response!` | `send_binary_response!` | transport/mongoose/connection.jl |
| `_is_x_request_id` | `is_request_id_header` | transport/mongoose/http_handler.jl |

### 1.4 Decouple Transport from Server
Create an interface layer between transport and server:

```julia
# New file: src/server/interface.jl
"""
Functions that the transport layer calls into the server layer.
Transport never accesses server.core.* directly.
"""
get_router(server::AbstractServer) = server.core.router
get_middlewares(server::AbstractServer) = server.core.middlewares
get_mounts(server::AbstractServer) = server.core.mounts
get_max_body(server::AbstractServer) = server.core.max_body
get_errors(server::AbstractServer) = server.core.errors
next_request_id!(server::AbstractServer) = ...
```

### 1.5 Test Infrastructure Improvements
- [ ] Add `@testset_logged` macro that prints server port + test name on start
- [ ] Add timeout wrapper for each `with_server` block (fail fast on hangs)
- [ ] Add retry logic for BindError in `with_server`
- [ ] Log which port is allocated for each test

---

## Phase 2: Core Feature Parity (v0.5)
**Goal:** Match FastAPI's core request/response cycle capabilities.

### 2.1 Request Body Parsing

```julia
# JSON body → Julia type
route!(router, :post, "/users") do req
    user = parse_body(req, CreateUser)  # Throws ValidationError on failure
    # user is typed, validated CreateUser instance
    Response(Json, user; status=201)
end

# Built-in parsers:
parse_body(req, ::Type{T})              # JSON → T (via StructTypes or JSON3)
parse_form(req)                          # application/x-www-form-urlencoded → Dict
parse_multipart(req)                     # multipart/form-data → MultipartData
```

Implementation:
- [ ] `src/http/parsing.jl` — JSON body parsing with type coercion
- [ ] `src/http/forms.jl` — URL-encoded form parsing
- [ ] `src/http/multipart.jl` — Multipart form parsing (file uploads)
- [ ] `ValidationError` type with structured error response (422)
- [ ] Content-Type dispatch for auto-parsing

### 2.2 Response Auto-Serialization

```julia
# Before:
route!(router, :get, "/users/:id") do req, id
    user = find_user(id)
    Response(Json, JSON.json(user))
end

# After:
route!(router, :get, "/users/:id") do req, id
    user = find_user(id)
    json(user; status=200)  # or just return the struct if response type declared
end

# Helper functions:
json(data; status=200, headers=[])        # → Response(Json, serialize(data); ...)
html(content; status=200)                 # → Response(Html, content; ...)
text(content; status=200)                 # → Response(Plain, content; ...)
redirect(url; status=302)                 # → Response with Location header
file(path; download=false)                # → Response with file content
```

### 2.3 Typed Query & Path Parameters

```julia
# Path params already work: /users/:id::Int
# Add query param extraction:
route!(router, :get, "/search") do req
    q = query(req, "q", String)           # required, throws 422 if missing
    page = query(req, "page", Int; default=1)
    limit = query(req, "limit", Int; default=20, max=100)
    # ...
end
```

### 2.4 Error Handler Registry

```julia
# Register exception → response mapping
on_error!(server, ValidationError) do err
    Response(Json, json_errors(err); status=422)
end

on_error!(server, NotFoundError) do err
    Response(Json, Dict("error" => err.message); status=404)
end

# Unhandled exceptions → 500 with configurable detail level
```

### 2.5 TestClient (In-Process Testing)

```julia
using Mongoose: TestClient

client = TestClient(server)

# No network, no port allocation, no startup delay
resp = client.get("/users"; headers=["Authorization" => "Bearer token"])
@test resp.status == 200
@test resp.json["name"] == "Alice"

resp = client.post("/users"; json=Dict("name" => "Bob"))
@test resp.status == 201
```

Implementation:
- [ ] `src/testing/client.jl` — Creates Request objects directly, invokes pipeline
- [ ] Bypasses FFI layer entirely (pure Julia path)
- [ ] Returns `TestResponse` with helper methods (.json, .text, .headers)

### 2.6 Compression Middleware

```julia
plug!(server, compress(; algorithms=[:gzip, :deflate], min_size=1024))
```

- [ ] Check `Accept-Encoding` header
- [ ] Compress response body if above min_size
- [ ] Set `Content-Encoding` header
- [ ] Use CodecZlib.jl for gzip/deflate

### 2.7 Background Tasks

```julia
route!(router, :post, "/webhook") do req
    payload = parse_body(req, WebhookPayload)
    background!(process_webhook, payload)  # Runs after response sent
    Response(202, "", "accepted")
end
```

Implementation:
- [ ] Task queue per server (`Channel{Function}`)
- [ ] Background worker drains queue after response dispatch
- [ ] Configurable max concurrent background tasks

---

## Phase 3: Production Polish (v0.6)
**Goal:** Production-ready with monitoring, docs, and operational excellence.

### 3.1 OpenAPI Generation

```julia
# Route metadata
route!(router, :get, "/users/:id::Int",
    handler;
    summary="Get user by ID",
    tags=["users"],
    responses=Dict(
        200 => UserResponse,
        404 => ErrorResponse
    )
)

# Auto-generate spec
spec = openapi(server)  # → OpenAPI 3.1 Dict
route!(router, :get, "/openapi.json", req -> json(spec))

# Built-in Swagger UI
swagger_ui!(server, "/docs")
```

### 3.2 Dependency Injection (Extractors)

Axum-style extractors — type-driven parameter resolution:

```julia
# Define extractors
struct CurrentUser
    id::Int
    name::String
end

function extract(::Type{CurrentUser}, req::Request)
    token = get(req.headers, "authorization", nothing)
    token === nothing && throw(UnauthorizedError())
    decode_jwt(token)
end

# Use in handlers — extracted automatically
route!(router, :get, "/profile") do req, user::CurrentUser
    json(Dict("name" => user.name))
end
```

### 3.3 Request/Response Lifecycle Hooks

```julia
on_request!(server) do req
    # Before any middleware — logging, tracing
    context!(req, :trace_id, generate_trace_id())
end

on_response!(server) do req, resp
    # After all middleware — metrics, cleanup
    emit_metric(:request_duration, elapsed(req))
end

on_error!(server) do req, err
    # Any unhandled exception
    report_to_sentry(err)
end
```

### 3.4 Graceful Shutdown Improvements

- [ ] `SIGTERM` / `SIGINT` handler registration
- [ ] Configurable drain timeout
- [ ] Connection drain with in-flight request tracking
- [ ] Health endpoint returns 503 during drain
- [ ] WebSocket close frames sent to all clients

### 3.5 Connection Limits & Backpressure

```julia
Server(router;
    max_connections=10_000,     # Reject new connections above limit
    max_requests_per_conn=100,  # Close connection after N requests
    idle_timeout=60,            # Close idle connections
)
```

### 3.6 Structured Logging Overhaul

```julia
# Replace custom logging with Julia's standard logging
using Logging

# Structured JSON logging for production
set_logger!(server, JSONLogger(; level=Info))

# Access log format
plug!(server, access_log(; format=:combined, output=stdout))
```

---

## Phase 4: Ecosystem & Scale (v1.0)
**Goal:** Feature-complete, battle-tested, ecosystem-ready.

### 4.1 Plugin System

```julia
# Plugins register routes, middleware, and services
struct AuthPlugin <: Plugin
    config::AuthConfig
end

function install!(server, plugin::AuthPlugin)
    plug!(server, plugin.middleware)
    route!(server.router, :post, "/auth/login", plugin.login_handler)
    route!(server, :post, "/auth/refresh", plugin.refresh_handler)
    register!(server, :auth, plugin.service)
end

install!(server, AuthPlugin(config))
```

### 4.2 WebSocket Rooms & Broadcasting

```julia
ws!(router, "/chat/:room") do conn, msg
    room = conn.params["room"]
    broadcast!(room, "$(conn.id): $(msg.data)")  # Send to all in room
end
```

### 4.3 HTTP Client (Upstream Calls)

```julia
# Built-in HTTP client for microservices
resp = fetch!("https://api.example.com/data";
    timeout=5000,
    retry=3,
    circuit_breaker=true
)
```

### 4.4 Distributed Tracing

- OpenTelemetry integration
- W3C Trace Context propagation
- Span creation for each request
- Context propagation through middleware

### 4.5 Admin Dashboard

```julia
admin!(server, "/admin";
    auth=bearer("admin-token"),
    features=[:metrics, :routes, :connections, :config]
)
```

---

## Implementation Order (Priority Queue)

| # | Task | Phase | Effort | Impact | Dependencies |
|---|------|-------|--------|--------|--------------|
| 1 | Structured Response headers | 1.2 | Medium | Critical | None |
| 2 | Remove dynamic.jl | 1.1 | Small | High | None |
| 3 | Naming standardization | 1.3 | Small | Medium | None |
| 4 | Test logging/diagnostics | 1.5 | Small | High | None |
| 5 | TestClient | 2.5 | Medium | Critical | #1 |
| 6 | JSON body parsing | 2.1 | Medium | Critical | None |
| 7 | Response helpers (json/html/text) | 2.2 | Small | High | #1 |
| 8 | Query param extraction | 2.3 | Small | High | None |
| 9 | Error handler registry | 2.4 | Medium | High | #1 |
| 10 | Compression middleware | 2.6 | Medium | Medium | #1 |
| 11 | Test coverage to 90%+ | All | Large | Critical | #4, #5 |
| 12 | OpenAPI generation | 3.1 | Large | High | #6, #7, #8 |
| 13 | Extractors/DI | 3.2 | Large | High | #6 |
| 14 | Background tasks | 2.7 | Small | Medium | None |
| 15 | Multipart parsing | 2.1 | Medium | Medium | None |

---

## File Structure (Target)

```
src/
├── Mongoose.jl              # Module definition, exports
├── ffi/                     # C interop (unchanged)
│   ├── constants.jl
│   ├── structs.jl
│   └── bindings.jl
├── types/                   # All type definitions (NEW)
│   ├── request.jl
│   ├── response.jl
│   ├── formats.jl
│   ├── errors.jl
│   ├── ws.jl
│   └── config.jl
├── router/                  # Routing (simplified)
│   ├── trie.jl             # Single router implementation
│   ├── groups.jl
│   └── static.jl           # @router macro
├── middleware/              # Middleware (unchanged)
│   ├── pipeline.jl
│   ├── cors.jl
│   ├── ratelimit.jl
│   ├── auth.jl
│   ├── logger.jl
│   ├── health.jl
│   ├── metrics.jl
│   ├── security.jl
│   └── compress.jl         # NEW
├── parsing/                 # Request parsing (NEW)
│   ├── json.jl
│   ├── forms.jl
│   ├── multipart.jl
│   └── query.jl
├── server/                  # Server lifecycle
│   ├── core.jl
│   ├── sync.jl
│   ├── async.jl
│   ├── lifecycle.jl
│   ├── registry.jl
│   └── interface.jl        # NEW: transport interface
├── transport/               # FFI adapter
│   └── mongoose/
│       ├── adapter.jl
│       ├── connection.jl
│       ├── events.jl
│       ├── http_handler.jl
│       └── ws_handler.jl
├── streaming/
│   └── sse.jl
├── testing/                 # NEW
│   └── client.jl
└── util/
    ├── errors.jl
    ├── strings.jl
    └── log.jl
```

---

## Breaking Changes Summary

| Change | Migration |
|--------|-----------|
| `Response(status, header_str, body)` removed | Use `Response(format, body; status, headers)` |
| `_`-prefixed functions renamed | Search & replace (internal only) |
| `dynamic.jl` deleted | Already unused |
| `Config` is only constructor path | Replace kwargs with `Config(...)` |
| `encode(::Type{T}, body)` signature | No external impact (internal dispatch) |

---

## Success Metrics

| Metric | Current | Target (v0.5) | Target (v1.0) |
|--------|---------|---------------|---------------|
| Test coverage | ~65% | >90% | >95% |
| Tests passing | 352 | 600+ | 1000+ |
| Latency (p99, simple GET) | ~0.2ms* | <0.15ms | <0.1ms |
| Throughput (simple GET) | ~100k rps* | >150k rps | >200k rps |
| Memory per request | ~2KB* | <1.5KB | <1KB |
| Time to first request (AOT) | ~50ms* | <30ms | <20ms |
| Features vs FastAPI | ~40% | ~70% | ~90% |

*Estimated, needs benchmarking.
