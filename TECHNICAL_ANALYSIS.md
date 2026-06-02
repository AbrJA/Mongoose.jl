# Mongoose.jl — Technical Analysis & Production Readiness Report

## Executive Summary

Mongoose.jl is a Julia web framework built on top of the Mongoose C library via FFI. It provides HTTP/WebSocket serving with both sync and async modes, middleware pipeline, routing (dynamic trie + static macro-generated), and transport-layer abstraction. While the architecture demonstrates thoughtful design in many areas, several structural issues prevent it from achieving FastAPI-level production readiness, modularity, and community extensibility.

This report identifies **design coupling issues**, **missing production features**, **naming inconsistencies**, and proposes a comprehensive refactoring plan.

---

## 1. Architecture Assessment

### 1.1 Current Strengths
- **Zero-copy FFI adapter**: Clean boundary between C types and Julia types
- **Dual routing**: Static (compile-time, AOT-safe) + Dynamic (runtime trie)
- **Onion middleware model**: Composable pipeline with before/after hooks
- **Sharded concurrency**: Rate limiter and metrics use lock-sharded designs
- **GC-safe callback design**: Object ID registry prevents GC race conditions
- **Streaming support**: Chunked transfer encoding via `StreamResponse`

### 1.2 Critical Design Issues

#### Issue 1: Server-Router Coupling (High Severity)
The `Server{R}` and `Async{R}` types are parametric on the router type. This creates tight coupling:
- Cannot swap routers at runtime
- C function pointers (`cfunc_sync`, `cfunc_async`) are generated per-router-type
- The `@router` macro generates type-specific C callbacks that cast servers to `Server{AppType}`
- `invoke_http` has a specialization for `Server{<:StaticRouter}` that bypasses middleware entirely

**Impact**: Cannot compose features independently. Adding a new server mode requires touching router code.

#### Issue 2: Mixed Abstraction Levels in `ServerCore`
`ServerCore` holds everything: connection state, configuration, routing, middleware, mounts, services. This "god object" pattern makes it impossible to:
- Test components in isolation
- Replace individual subsystems
- Extend without touching core

#### Issue 3: Response Type Coupling
`Response` uses pre-formatted header strings (`String`) instead of structured data:
```julia
struct Response
    status::Int
    headers::String          # Pre-serialized "Key: Value\r\n" format
    body::Union{String,Vector{UInt8}}
end
```
This means:
- Headers cannot be inspected/modified after creation
- Middleware that needs to add headers must do string concatenation
- No way to implement response transformation cleanly

#### Issue 4: Middleware Cannot Access Server State
Middleware receives only `(req, next)` — no access to services, config, or server state. This forces:
- Services injection via `context!` hack in `invoke_http`
- Health middleware hardcodes paths instead of being configurable via the framework

#### Issue 5: Missing Request Lifecycle Hooks
No support for:
- `on_startup` / `on_shutdown` events
- Background tasks tied to server lifecycle
- Dependency injection at the framework level (only via ServiceRegistry hack)

#### Issue 6: Static Router Bypasses Middleware
```julia
@inline function invoke_http(server::Server{<:StaticRouter}, req::Request)::Union{Response,StreamResponse}
    return dispatch_static(server.core.router, req)
end
```
This means static routers cannot use middleware at all — a fundamental limitation that breaks the middleware contract.

---

## 2. Missing Production Features (vs FastAPI)

| Feature | FastAPI | Mongoose.jl | Gap |
|---------|---------|-------------|-----|
| Request validation | Pydantic models | None | Critical |
| Auto API docs (OpenAPI) | Built-in | None | Critical |
| Dependency injection | First-class DI | ServiceRegistry (bolted on) | High |
| Background tasks | Built-in | None | High |
| Lifespan events | `@app.on_event` | None | High |
| Response models | Type-checked | None | Medium |
| Path operation metadata | Tags, summary, deprecated | None | Medium |
| File upload handling | UploadFile | None | High |
| Form data parsing | Built-in | None | High |
| JSON serialization | Auto via Pydantic | Manual `encode()` extension | High |
| Error handlers | Exception handlers | `fail!()` for status codes only | Medium |
| Middleware state | Full access | No server access | High |
| Testing utilities | TestClient | `with_server` (basic) | Medium |
| Request timeout | Per-route | Global only (Async) | Medium |
| Graceful shutdown hooks | Signal handlers | InterruptException only | Medium |
| Content negotiation | Built-in | None | Medium |
| Redirect helpers | Built-in | None | Low |
| Dependency overrides (testing) | Built-in | None | Medium |

---

## 3. Naming Convention Issues

### 3.1 Incorrect `!` Usage (Mutation Convention Violation)
Julia convention: `!` suffix indicates the function **mutates its arguments**.

| Function | Mutates? | Should Have `!`? | Verdict |
|----------|----------|-----------------|---------|
| `start!` | Yes (modifies server state) | Yes | ✅ Correct |
| `shutdown!` | Yes (modifies server state) | Yes | ✅ Correct |
| `route!` | Yes (modifies router) | Yes | ✅ Correct |
| `plug!` | Yes (modifies server) | Yes | ✅ Correct |
| `mount!` | Yes (modifies server) | Yes | ✅ Correct |
| `fail!` | Yes (modifies server) | Yes | ✅ Correct |
| `context!` | Yes (lazily creates dict) | Borderline | ⚠️ Keep for clarity |
| `ws!` | Yes (modifies router) | Yes | ✅ Correct |
| `event!` | No (writes to stream) | No | ❌ Should be `emit` or `send` |
| `register_group!` | Yes (modifies router) | Yes | ✅ But name too long |
| `register!` | Yes (modifies registry) | Yes | ✅ Correct |

### 3.2 Inconsistent Export Naming Style

Current exports mix three styles:
1. **Single word, no underscore**: `cors`, `ratelimit`, `bearer`, `apikey`, `logger`, `health`, `metrics`, `security`
2. **Two words with underscore**: `serialize_cookie`, `parse_cookies`, `register_group!`, `sse_response`
3. **Abbreviations**: `ws!`

**Target**: Short, clear names. One word preferred. Two words without underscore if needed.

### 3.3 Proposed Naming Changes

| Current | Proposed | Rationale |
|---------|----------|-----------|
| `serialize_cookie` | `bake` | Idiomatic "bake a cookie" metaphor, short |
| `parse_cookies` | `cookies` | Noun = getter pattern |
| `register_group!` | `mount!` overload | Groups are just prefix mounting |
| `sse_response` | `sse` | Shorter, clear from context |
| `event!` | `emit` | Doesn't mutate SSEWriter, just writes |
| `context!` | `ctx!` | Shorter, still clear |
| `apikey` | `apikey` | ✅ Already good |
| `ratelimit` | `ratelimit` | ✅ Already good |
| `fail!` | `onerror!` | More descriptive |
| `register!` | `provide!` | DI terminology |
| `service` | `inject` | DI terminology |

---

## 4. RFC Compliance Issues

### 4.1 HTTP/1.1 (RFC 9110/9112)
- ❌ No `Transfer-Encoding` validation on incoming requests
- ❌ No `100 Continue` handling for `Expect` header
- ❌ No `Connection: keep-alive` management (delegated to C library)
- ❌ No proper `Content-Length` validation vs actual body
- ⚠️ HEAD responses may include body-related headers without body (partially handled)

### 4.2 WebSocket (RFC 6455)
- ❌ No fragmented message reassembly (single-frame only)
- ❌ No per-message compression (permessage-deflate)
- ❌ No sub-protocol negotiation
- ⚠️ Close frame handling exists but no status code reporting to user

### 4.3 CORS (RFC 6454 / Fetch spec)
- ❌ No `Vary: Origin` header when origin is not `*`
- ❌ No credential support (`Access-Control-Allow-Credentials`)
- ❌ No per-route CORS configuration

### 4.4 Cookies (RFC 6265)
- ✅ Set-Cookie serialization is correct
- ❌ No `__Host-` / `__Secure-` prefix validation
- ❌ No cookie signing/encryption support

---

## 5. Performance Analysis

### 5.1 Hot Path Allocations
- **Query parsing**: Allocates `Dict{String,String}` per request even when query is empty (fast path exists but still allocates)
- **Header parsing**: Allocates `Vector{Pair{String,String}}` per request — could use a pooled buffer
- **Middleware chain**: Creates one closure per middleware per request (`_build_chain` is recursive)
- **Response construction**: String concatenation for headers in middleware (`mw.headers * response.headers`)

### 5.2 Concurrency Design
- **SpinLock in registry**: Correct for non-yielding C callback context
- **Sharded rate limiter**: Good design, but cleanup iterates all entries under lock
- **Worker pool**: Fixed size, no auto-scaling. Channel-based which has overhead vs lock-free queues

### 5.3 Memory
- **No connection pooling**: Each request creates new Julia objects
- **No response caching**: Every identical response re-allocates
- **MgConnection as Ptr{Cvoid}**: Type-unsafe, no lifetime tracking

---

## 6. Proposed Architecture (v1.0)

### 6.1 Core Principles
1. **Decoupled components**: Server, Router, Middleware, Transport are independent
2. **Protocol-first**: Define interfaces (traits), implementations are swappable
3. **Zero-cost abstractions**: Use Julia's type system for compile-time dispatch
4. **Convention over configuration**: Sensible defaults, minimal boilerplate
5. **Testable**: Every component works in isolation

### 6.2 New Module Structure
```
src/
  Mongoose.jl              # Module definition, exports
  types.jl                 # All public types in one place
  app.jl                   # App (replaces Server/Async, unified API)
  router.jl                # Router (trie-based, no more static macro needed)
  handler.jl               # Request → Response dispatch
  middleware.jl            # Pipeline + built-in middleware
  request.jl               # Request type
  response.jl              # Response type + helpers
  websocket.jl             # WebSocket types and handling
  sse.jl                   # SSE support
  static.jl                # Static file serving
  ffi/                     # C library bindings (unchanged)
    bindings.jl
    constants.jl
    structs.jl
  transport/               # Transport adapter (FFI → Julia)
    adapter.jl
    connection.jl
    events.jl
    loop.jl
  middleware/              # Built-in middleware (each is self-contained)
    cors.jl
    ratelimit.jl
    auth.jl
    logger.jl
    health.jl
    metrics.jl
    security.jl
  util/
    errors.jl
    strings.jl
    log.jl
```

### 6.3 Unified App API (FastAPI-inspired)
```julia
app = App(; workers=4, timeout=30_000)

# Routes
get!(app, "/") do req
    json(Dict("message" => "Hello"))
end

post!(app, "/users") do req
    body = json(req)
    json(Dict("id" => 1, "name" => body["name"]); status=201)
end

get!(app, "/users/:id::Int") do req, id
    json(Dict("id" => id))
end

# Middleware
use!(app, cors())
use!(app, ratelimit(max=100, window=60))
use!(app, logger())

# Lifecycle
onstart!(app) do
    println("Server starting...")
end

onstop!(app) do
    println("Server stopping...")
end

# Static files
serve!(app, "public/", prefix="/static")

# Start
start!(app; port=8080)
```

### 6.4 Response Helpers (FastAPI-style)
```julia
# Instead of Response(Json, Dict(...))
json(data; status=200, headers=[])
html(content; status=200)
text(content; status=200)
redirect(url; status=302)
file(path; download=false)
sse(producer)
stream(producer; content_type="application/octet-stream")
```

### 6.5 Structured Response Type
```julia
struct Response
    status::Int
    headers::Vector{Pair{String,String}}  # Structured, inspectable
    body::Union{String,Vector{UInt8}}
    _serialized_headers::String           # Cached serialization (lazy)
end
```

### 6.6 Middleware with Context
```julia
abstract type Middleware end

# Middleware receives a Context object with full access
function (mw::Middleware)(ctx::Context, next::Function)
    # ctx.request, ctx.app, ctx.services, ctx.state
end
```

---

## 7. Simplification Opportunities

### 7.1 Remove
- **`@router` macro**: Over-engineered for AOT. The dynamic router with precompilation is sufficient for 99% of use cases. If AOT is needed, it can be a separate package.
- **`StaticRouter` type hierarchy**: Removes parametric `Server{R}` complexity
- **`ServerCore` god object**: Split into focused components
- **`Config` struct**: Use keyword arguments directly (Julia style)
- **`ServiceRegistry` as separate concept**: Integrate into App
- **`RouteGroup`**: Replace with simple prefix mounting via `mount!`
- **Dual `Server`/`Async` types**: Unified `App` with `workers=0` for sync mode
- **`Tagged`, `Call`, `Reply`**: Internal types that leak complexity

### 7.2 Simplify
- **Response headers**: Use `Vector{Pair}` consistently, serialize on send
- **Middleware registration**: `use!` instead of `plug!`
- **Route registration**: Method-specific functions (`get!`, `post!`, etc.)
- **Error handling**: Exception-based with `onerror!` handlers
- **WebSocket API**: Simpler channel-based communication

---

## 8. Security Gaps

| Gap | Severity | Recommendation |
|-----|----------|----------------|
| No CSRF protection middleware | Medium | Add `csrf()` middleware |
| No request size limit per-route | Medium | Add per-route `max_body` |
| No IP allowlist/blocklist | Low | Add `allowlist()` middleware |
| Header injection possible in custom headers | High | Validate all user-provided header values |
| No rate limit by route/method | Medium | Support route-scoped rate limiting |
| `sanitize_header_value` only checks length+CRLF | Medium | Also validate against HTTP token grammar |
| Static file serving has no cache headers | Low | Add `Cache-Control` configuration |

---

## 9. Testing Gaps

Current test coverage is reasonable for happy paths but lacks:
- **Edge cases**: Malformed requests, huge headers, slow clients
- **Concurrency stress**: Race conditions under load
- **Middleware composition**: Complex chains with error propagation
- **WebSocket**: Fragmented frames, rapid connect/disconnect, binary data
- **Memory leak detection**: Long-running server tests
- **Benchmark regression tests**: Performance assertions

---

## 10. Summary of Priority Actions

1. **Unify Server API** → Single `App` type with `workers` parameter
2. **Fix Response headers** → Structured `Vector{Pair}`, serialize on send
3. **Add response helpers** → `json()`, `html()`, `text()`, `redirect()`
4. **Rename exports** → Short, consistent, Julia-idiomatic
5. **Middleware context** → Pass app/services to middleware
6. **Remove @router macro** → Simplify to one router type
7. **Add lifecycle hooks** → `onstart!`, `onstop!`
8. **Add missing features** → Form parsing, file upload, background tasks
9. **Fix RFC compliance** → CORS Vary header, WebSocket close codes
10. **Comprehensive tests** → >80% coverage with edge cases
