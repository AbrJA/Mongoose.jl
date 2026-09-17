# Mongoose.jl — Architecture Analysis & Production Readiness Report

## Executive Summary

Mongoose.jl is a Julia HTTP/WebSocket framework wrapping the Mongoose C library. While the current implementation demonstrates solid performance engineering (zero-allocation hot paths, trie-based routing, sharded locks), it has several architectural issues that prevent it from competing with production frameworks like FastAPI, Actix-web, or Gin. This report identifies the key issues and proposes a comprehensive refactoring plan.

---

## 1. Critical Architecture Issues

### 1.1 God Object: `App` struct (30+ fields)

**Problem:** The `App` struct in `server/core.jl` is a monolithic mutable struct with 30+ fields mixing concerns:
- C FFI state (manager, c_handler)
- Connection tracking (ws_clients, id_seq)
- Routing (router, middlewares, mounts)
- Error handling (errors)
- Dependency injection (services)
- Lifecycle hooks (hooks_start, hooks_stop, bg_tasks)
- Tuning parameters (6 timeout/size fields)
- Async worker pool (workers, queuesize, worker_tasks, calls, replies, connections, inflight)

**Impact:**
- Impossible to test components in isolation
- Every new feature adds fields to this struct
- Type instability: `Union{Response,Function}` in errors dict, `Dict{Symbol,Any}` for services
- No separation between configuration and runtime state

### 1.2 Tight Coupling Between Transport and Application Logic

**Problem:** The HTTP handler (`http_handler.jl`) directly knows about:
- The `App` struct internals (`.workers`, `.middlewares`, `.services`, `.errors`)
- The router dispatch mechanism
- Connection tracking for async mode
- Static file serving

**Impact:** Cannot swap transports, test handlers without a full server, or add new protocols.

### 1.3 Missing HTTP/1.1 RFC Compliance

| Feature | Status | RFC |
|---------|--------|-----|
| Chunked Transfer-Encoding (request) | ❌ Missing | RFC 7230 §4.1 |
| Expect: 100-continue | ❌ Missing | RFC 7231 §5.1.1 |
| Connection: keep-alive management | ⚠️ Delegated to C | RFC 7230 §6.3 |
| Content-Length validation | ⚠️ Partial | RFC 7230 §3.3.3 |
| Trailer headers | ❌ Missing | RFC 7230 §4.4 |
| Range requests (app-level) | ❌ Only static files | RFC 7233 |
| Conditional requests (If-Match, etc) | ❌ Missing | RFC 7232 |
| Content negotiation (Accept header) | ❌ Missing | RFC 7231 §5.3 |
| Multipart form data parsing | ❌ Missing | RFC 7578 |
| Proper URI normalization | ⚠️ Partial | RFC 3986 |

### 1.4 Missing Production Features (vs FastAPI)

| Feature | FastAPI | Mongoose.jl | Priority |
|---------|---------|-------------|----------|
| Request/response validation | Pydantic models | ❌ None | Critical |
| OpenAPI/Swagger auto-generation | ✅ Built-in | ❌ Missing | Critical |
| Dependency injection (typed) | ✅ `Depends()` | ⚠️ `Dict{Symbol,Any}` | High |
| Background tasks | ✅ `BackgroundTasks` | ⚠️ Basic | Medium |
| File uploads (multipart) | ✅ `UploadFile` | ❌ Missing | Critical |
| Form data parsing | ✅ `Form()` | ⚠️ Basic URL-encoded only | High |
| Path operation decorators | ✅ `@app.get()` | ⚠️ `get!(app, path, f)` | Medium |
| Response models | ✅ Type-checked | ❌ None | High |
| Exception handlers | ✅ Typed dispatch | ⚠️ Status-code only | Medium |
| Lifespan events | ✅ `@asynccontextmanager` | ⚠️ Hooks only | Low |
| Testing client | ✅ `FakeTransport` | ❌ Must use HTTP.jl | High |
| WebSocket rooms/broadcasting | ✅ Via Starlette | ❌ Missing | Medium |
| Request body streaming | ✅ Built-in | ❌ Missing | Medium |
| GZip compression middleware | ✅ Via middleware | ❌ Missing | Medium |
| CSRF protection | ✅ Via middleware | ❌ Missing | Medium |
| Session management | ✅ Via middleware | ❌ Missing | Medium |
| Graceful shutdown signals | ✅ Built-in | ⚠️ Basic | Low |

### 1.5 Type Instability Issues

```julia
# In App struct:
errors::Dict{Int,Union{Response,Function}}     # Union dispatch
services::Dict{Symbol,Any}                      # Fully untyped
context::Union{Nothing,Dict{Symbol,Any}}        # Lazy alloc but untyped

# In routing:
params::Vector{Any}                             # Should be type-parameterized
handlers::Union{Nothing,Function}               # Function is abstract

# In pipeline:
execute_pipeline returns Union{Response,StreamResponse}  # Acceptable but could be narrower
```

### 1.6 Overengineered Areas (Complexity Without Value)

1. **`_is_x_request_id()` byte-by-byte comparison**: Micro-optimization that adds 15 lines for a cold path. `lowercase(to_string(h.name)) == "x-request-id"` is equally fast in practice.

2. **`uint_to_string()` manual implementation**: `string(n)` is already optimized in Base Julia. The custom version is allocation-equivalent.

3. **Dual logging backends (JIT/AOT)**: The AOT path adds complexity for a niche use case. Should be a separate package or extension.

4. **`MgConnection` as `Ptr{Cvoid}` typedef**: Loses type safety; should be a proper wrapper struct.

### 1.7 Missing Error Recovery Patterns

- No circuit breaker for downstream services
- No request retry logic
- No structured error types beyond `RouteError`/`ServerError`/`BindError`
- No error context propagation (stack traces lost in async workers)
- No panic recovery in WebSocket handlers (one bad frame = silent drop)

---

## 2. Design Pattern Recommendations

### 2.1 Composition Over Monolithic App

**Proposed pattern: Builder + Component Architecture**

```julia
# Instead of one giant App with 30 fields:
app = Mongoose.app() do builder
    builder |>
        with_router(Router()) |>
        with_workers(4) |>
        with_middleware([cors(), logger()]) |>
        with_services(db=connect_db()) |>
        with_tls(TLSConfig(...))
end
```

### 2.2 Protocol Trait System

```julia
# Define capabilities as traits, not inheritance:
abstract type AbstractHandler end

struct HttpHandler <: AbstractHandler
    router::Router
    middleware::Vector{AbstractMiddleware}
end

struct WsHandler <: AbstractHandler
    endpoints::Dict{String,WsEndpoint}
end
```

### 2.3 Typed Dependency Injection

```julia
# Instead of Dict{Symbol,Any}:
struct Services{T<:NamedTuple}
    deps::T
end

# Usage:
provide!(app, db=pool, cache=redis)
inject(req, :db)::PostgresPool  # Type-stable!
```

### 2.4 Request Validation via Julia's Type System

```julia
# FastAPI-style validation using dispatch:
struct CreateUser
    name::String
    email::String
    age::Int
end

post!(app, "/users") do req, body::CreateUser
    # body is already validated and parsed
end
```

---

## 3. Performance Opportunities

### 3.1 Current Bottlenecks (Estimated Impact)

| Bottleneck | Location | Impact |
|-----------|----------|--------|
| `Dict{String,String}` for query params | `parse_query()` | ~200ns per request |
| `Vector{Pair{String,String}}` header scan | `Headers.get()` | O(n) per lookup |
| `Vector{Any}` for route params | `dispatch_route()` | Boxing overhead |
| Closure allocation in pipeline | `_build_chain()` | ~50ns per middleware |
| `IOBuffer` in `format_headers()` | `connection.jl` | Allocation per response |

### 3.2 Proposed Optimizations

1. **Pre-allocated response buffers** per worker thread (thread-local storage)
2. **Header indexing**: Switch to sorted vector with binary search for >5 headers
3. **Route params as Tuple**: `(id::Int, slug::String)` instead of `Vector{Any}`
4. **Inlined middleware chains**: Generate specialized dispatch for known chains at registration time
5. **Connection pooling**: Reuse connection objects instead of creating new ones per request

---

## 4. Modularity Improvements

### 4.1 Current Module Boundary Issues

```
Problem: Everything is one module (Mongoose)
- Cannot load just the router without the FFI layer
- Cannot test middleware without Request/Response
- Cannot use the protocol types in other packages
```

### 4.2 Proposed Internal Sub-module Structure

```
Mongoose.jl (facade)
├── Core (Request, Response, Headers, Status, Formats)
├── Router (Trie, MethodMap, RouteGroup)
├── Middleware (Pipeline, AbstractMiddleware, PathFilter)
├── Transport (FFI adapter, Connection, Events)
└── Extensions (CORS, RateLimit, Auth, Metrics, SSE, Security)
```

The key insight: **Core** should be completely independent of Transport. Router should only depend on Core. This enables:
- Testing handlers without any server
- Swapping the C mongoose transport for a pure-Julia transport
- Using the middleware system in other contexts

---

## 5. Recommended Simplifications

### 5.1 Remove or Simplify

1. **Remove `plug!` alias** → Just `use!` (one way to do things)
2. **Remove `event!` alias** → Just `emit`
3. **Remove `sse_response` alias** → Just `sse`
4. **Simplify `init_server!`** → Only called once, can be in constructor
5. **Remove the `AbstractRouter` interface** → Only one router impl, YAGNI
6. **Remove `route_count()`** → Debugging utility, not API
7. **Merge `lifecycle.jl` helpers into `core.jl`** → Reduces file count
8. **Remove dual-mode logging** → Use Julia's standard `@info/@warn/@error`

### 5.2 Naming Improvements

| Current | Proposed | Reason |
|---------|----------|--------|
| `ctx!(req)` | `context(req)` | More discoverable |
| `setcookie(cookie)` | `serialize(cookie)` or `to_header(cookie)` | Standard naming |
| `plug!(server, mw)` | Remove (keep only `use!`) | Duplicate API |
| `provide!(app, :name, val)` | `service!(app, :name, val)` | Clearer intent |
| `inject(req, :name)` | `service(req, :name)` | Pairs with above |

---

## 6. Testing Strategy

### 6.1 Current Test Coverage Gaps

- ❌ No unit tests for `adapter.jl` (FFI boundary)
- ❌ No unit tests for `connection.jl` (send functions)
- ❌ No unit tests for `events.jl` (dispatch logic)
- ❌ No tests for async worker pool edge cases (full queue, worker crash)
- ❌ No tests for `StreamResponse` end-to-end
- ❌ No tests for route groups with nested middleware
- ❌ No fuzz testing for query/URL parsing
- ❌ No concurrency stress tests
- ❌ No memory leak tests (GC pressure under load)

### 6.2 Proposed Test Architecture

```
test/
├── unit/                    # No I/O, no servers
│   ├── test_request.jl
│   ├── test_response.jl
│   ├── test_router.jl
│   ├── test_middleware.jl
│   ├── test_pipeline.jl
│   ├── test_formats.jl
│   ├── test_strings.jl
│   └── test_cookies.jl
├── integration/             # Server started, HTTP requests
│   ├── test_http.jl
│   ├── test_websocket.jl
│   ├── test_static.jl
│   ├── test_tls.jl
│   ├── test_streaming.jl
│   └── test_async.jl
├── middleware/              # Each middleware tested independently
│   ├── test_cors.jl
│   ├── test_ratelimit.jl
│   ├── test_auth.jl
│   ├── test_logger.jl
│   ├── test_metrics.jl
│   └── test_security.jl
└── quality/                 # Aqua + JET
    └── test_quality.jl
```

---

## 7. API Design Comparison with FastAPI

### FastAPI Pattern:
```python
@app.get("/users/{user_id}")
async def get_user(user_id: int, q: str = None):
    return {"user_id": user_id, "q": q}
```

### Current Mongoose.jl:
```julia
get!(app, "/users/:id::Int") do req, id
    json(Dict("user_id" => id, "q" => get(req.query, "q", nothing)))
end
```

### Proposed Mongoose.jl (improved):
```julia
get!(app, "/users/:id::Int") do req, id
    q = query(req, "q", nothing)  # Typed query param helper
    json((user_id=id, q=q))       # NamedTuple auto-serialization
end
```

---

## 8. Security Audit

### 8.1 Current Security Posture

| Category | Status | Notes |
|----------|--------|-------|
| CRLF injection prevention | ✅ `sanitize_header_value()` | Good |
| Body size limits | ✅ `max_body` enforcement | Good |
| WS frame size limits | ✅ `ws_max_frame` | Good |
| Path traversal (static) | ⚠️ Delegated to C lib | Should validate in Julia |
| SQL injection | N/A | No DB layer |
| XSS in error pages | ⚠️ Plain text bodies | Could be HTML if extended |
| Timing attacks (auth) | ❌ No constant-time compare | Should use `Base.constant_time_eq` |
| Rate limit bypass (IP spoofing) | ⚠️ Trusts X-Forwarded-For | Should be configurable |
| TLS cert validation | ⚠️ `skip_verification` option | Dangerous default if used |

### 8.2 Recommendations

1. Add `Base.constant_time_eq` for token comparison in auth middleware
2. Make IP extraction configurable (trust proxy headers only when configured)
3. Add request ID validation (prevent log injection via X-Request-Id)
4. Add Content-Security-Policy defaults in security middleware
5. Validate static file paths before passing to C library

---

## 9. Roadmap Summary

### Phase 1: Foundation (Breaking Changes)
- Decompose `App` into smaller composable structs
- Add typed DI system
- Add multipart form parsing
- Add request validation
- Fix type instabilities

### Phase 2: Features
- Content negotiation
- GZip compression middleware
- Session middleware
- WebSocket rooms/broadcasting
- FakeTransport for testing without network

### Phase 3: Ecosystem
- OpenAPI schema generation
- CLI tool for project scaffolding
- Plugin system for community extensions
- Benchmarking suite

### Phase 4: Polish
- Full RFC 7230-7235 compliance
- Documentation comparable to FastAPI
- Tutorial series
- Migration guide from HTTP.jl

---

## 9. Implemented Changes (v0.5.0)

The following simplifications and improvements from this report have been implemented:

### Dependency Changes
- **JSON3 → JSON**: Replaced JSON3.jl with JSON.jl (`import JSON`). Removed StructTypes dependency. `encode(Json, body)` now uses `JSON.json(body)`, `decode(Json, body)` uses `JSON.parse(body)`.
- **Removed typed deserialization**: `body(req, ::Type{T})` and `json(req, ::Type{T})` removed. Users parse JSON manually with `JSON.parse(body(req))`.

### API Renames (§5.2)
- `ctx!(req)` → `context(req)` ✅
- `provide!(app, :name, val)` → `service!(app, :name, val)` ✅
- `inject(req, :name)` → `service(req, :name)` ✅

### Simplifications (§5.1)
- **Removed `AbstractRouter` interface** (§5.1.5) ✅ — `Router` is now a concrete struct, no abstract supertype
- **Removed `uint_to_string`** — replaced with `string()` (stdlib)
- **Simplified `_isbearer`** — replaced manual byte comparison with `startswith(lowercase(...), "bearer ")`

### Version
- Bumped to 0.5.0 (breaking release)

### Validation
- All tests pass
- Aqua.jl: all checks pass (ambiguity, exports, compat, piracy, stale deps)
