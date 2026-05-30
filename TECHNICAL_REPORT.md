# Mongoose.jl — Technical Architecture Report & Production Readiness Assessment

**Date:** 2026-05-29
**Version analyzed:** 0.3.1 (branch `feat/modular`)
**Scope:** Full architecture review, coupling analysis, production gap assessment, and improvement roadmap.

---

## Executive Summary

Mongoose.jl is a Julia HTTP/WebSocket framework wrapping the Mongoose C library via FFI. The current implementation demonstrates solid fundamentals — a well-designed trie-based router, proper FFI isolation, and a composable middleware pipeline. However, several architectural issues prevent it from competing with production-grade frameworks like FastAPI, Actix-web, or Gin:

1. **Tight coupling** between the transport layer and application logic
2. **Duplicated code** across `Server`/`Async` paths (80+ lines of duplicated HTTP handlers)
3. **Missing fundamental HTTP features** (JSON body parsing, validation, dependency injection at route level, OpenAPI generation)
4. **Non-standard internal naming** (mixed `_prefix` and `camelCase`, inconsistent `!` usage)
5. **Dead/redundant code** (`src/core/`, `src/http/`, `src/servers/`, `src/ws/` directories contain stale/duplicated modules)
6. **Limited extensibility** — no plugin system, no hook lifecycle, no way to replace components
7. **Weak test architecture** — port conflicts, no isolation, missing coverage of edge cases

---

## 1. Architecture Analysis

### 1.1 Current Module Structure

```
src/
├── Mongoose.jl           # Module root — 223 lines, exports everything
├── core/                 # ⚠️ STALE — appears to be an older version of server/
├── ffi/                  # ✅ Clean FFI layer
├── http/                 # ⚠️ STALE — duplicates transport/mongoose/http_handler.jl
├── middleware/           # ✅ Good — but pipeline protocol is overcomplicated
├── protocol/             # ✅ Good — transport-agnostic types
├── router/               # ✅ Good — but static router macro is overly complex
├── server/               # ✅ Core server types and lifecycle
├── servers/              # ⚠️ STALE — duplicates server/
├── streaming/            # ✅ Good — SSE support
├── transport/mongoose/   # ✅ FFI adapter layer
├── util/                 # ✅ Utilities
└── ws/                   # ⚠️ STALE — duplicates transport/mongoose/ws_handler.jl
```

**Problem:** 4 directories (`core/`, `http/`, `servers/`, `ws/`) contain dead code that is never included by the main module. This creates confusion and maintenance burden.

### 1.2 Coupling Issues

#### A. Server ↔ Transport coupling

The `on_http_message` function in `transport/mongoose/http_handler.jl` has two separate implementations for `Server` and `Async` that share ~60% of their logic. The "shared" `preprocess_http` helps but doesn't fully eliminate duplication:

```julia
# Duplicated in http_handler.jl:
function on_http_message(server::Server, conn, ev_data)  # 30 lines
function on_http_message(server::Async, conn, ev_data)   # 40 lines
```

Both do: WS upgrade check → body size check → static serve → build request → attach services → dispatch. The only difference is sync dispatch vs. channel enqueue.

#### B. ServerCore monolith

`ServerCore{R}` is a 15-field mutable struct that combines:
- Runtime state (`running`, `master`, `manager`)
- Configuration (`poll_timeout`, `max_body`, `drain_timeout`)
- Application concerns (`router`, `middlewares`, `mounts`, `errors`)
- WebSocket state (`ws_clients`, `id_seq`)
- Transport state (`c_handler`, `tls`)

This violates the Single Responsibility Principle and makes testing individual components impossible without constructing the entire server.

#### C. Response type is stringly-typed headers

```julia
struct Response
    status::Int
    headers::String        # ← Raw header string, not structured
    body::Union{String,Vector{UInt8}}
end
```

This design optimizes for zero-copy sending to C but makes middleware header manipulation error-prone and impossible to inspect programmatically. Adding a header requires string concatenation; checking if a header exists requires parsing the string.

#### D. Middleware signature inconsistency

The `_pipeline` function in `core/types.jl` uses `(req, params, next)` but the actual middleware call operator uses `(req, next)`. The `core/types.jl` version appears to be dead code from an earlier iteration.

### 1.3 Design Pattern Issues

| Issue | Impact | Severity |
|-------|--------|----------|
| Global mutable `REGISTRY` | Makes testing difficult, prevents multiple server instances in tests | Medium |
| `objectid` as C callback recovery | Works but prevents server GC during callbacks | Low |
| `Threads.Atomic{Bool}` for running state | Not composable — no state machine for lifecycle | Medium |
| Response headers as raw String | Cannot inspect/modify headers programmatically | High |
| No error type hierarchy | All errors are strings, no structured error handling | High |
| Precompile workload in main module | Increases load time, should be in extension | Low |

---

## 2. Production Gaps vs. FastAPI

### 2.1 Missing Core Features

| Feature | FastAPI | Mongoose.jl | Priority |
|---------|---------|-------------|----------|
| **Request body parsing/validation** | Pydantic models, automatic JSON parsing | Manual `JSON.parse(req.body)` | Critical |
| **Response serialization** | Auto-JSON from return types | Manual `Response(Json, ...)` | Critical |
| **Path parameter validation** | Automatic with type hints | Types but no range/regex validation | High |
| **Query parameter parsing** | Typed with defaults & validation | Raw `Dict{String,String}` only | High |
| **Dependency injection** | `Depends()` at route level | Only `ServiceRegistry` (server-level) | Critical |
| **OpenAPI/Swagger generation** | Automatic from route definitions | None | High |
| **Form data parsing** | Built-in multipart support | None | Medium |
| **File uploads** | `UploadFile` type | None | Medium |
| **Background tasks** | `BackgroundTasks` in response | None | Medium |
| **Exception handlers** | `@app.exception_handler(...)` | Only `errors::Dict{Int,Response}` | High |
| **Lifespan events** | `@app.on_event("startup"/"shutdown")` | None | Medium |
| **Response models** | Typed response with field filtering | None | High |
| **Request validation errors** | 422 with detailed error body | None (returns 404/500) | Critical |
| **Content negotiation** | Via Accept header | None | Medium |
| **Redirect responses** | `RedirectResponse` | Manual header construction | Low |
| **Cookie reading** | `Request.cookies` | No cookie parsing on request | Medium |
| **CORS per-route** | Configurable per-route | Global only | Medium |

### 2.2 Missing Production Infrastructure

| Feature | Status | Impact |
|---------|--------|--------|
| **Structured logging** | Partial (logger middleware has `structured=true`) | Medium |
| **Request/Response hooks** | None — can't intercept globally without middleware | High |
| **Graceful zero-downtime restart** | Missing | Medium |
| **Connection draining** | Basic (time-based only) | Low |
| **Circuit breaker** | None | Medium |
| **Request tracing (OpenTelemetry)** | None | Medium |
| **Compression (gzip/brotli)** | C-level static only, not for dynamic responses | High |
| **ETag generation for responses** | None for dynamic content | Low |
| **Request size limiting per-route** | Global only | Medium |
| **Timeout per-route** | Global only (Async) | Medium |
| **API versioning** | Manual (via route groups) | Low |

### 2.3 Developer Experience Gaps

| Feature | FastAPI | Mongoose.jl |
|---------|---------|-------------|
| Interactive docs (Swagger UI) | Built-in at `/docs` | None |
| Auto-reload in development | Via uvicorn --reload | None |
| Type-safe route returns | Enforced by response_model | No enforcement |
| Error messages | Detailed 422 with field errors | Generic 404/500 |
| Testing utilities | `TestClient` | Must use HTTP.jl externally |
| CLI tool | `uvicorn` / `fastapi` CLI | None |

---

## 3. Code Quality Issues

### 3.1 Naming Convention Violations (Julia Standards)

Julia convention: internal functions should be lowercase with underscores. No leading `_` unless truly private implementation detail. `!` suffix for mutating functions.

| Current | Issue | Proposed |
|---------|-------|----------|
| `_pipeline` | Leading underscore but it's a core abstraction | `run_pipeline` |
| `_shard` | Fine — truly internal | Keep |
| `_isbearer` | Fine — truly internal | Keep |
| `_RateShard` | Struct names shouldn't have `_` prefix | `RateLimitShard` |
| `_MetricsShard` | Same | `MetricsShard` |
| `_RATE_LIMIT_SHARDS` | Constants shouldn't have `_` prefix | `RATE_LIMIT_SHARDS` |
| `_METRICS_SHARDS` | Same | `METRICS_SHARDS` |
| `_HIST_BOUNDS` | Same | `HIST_BOUNDS` |
| `_N_HIST_BUCKETS` | Same | `N_HIST_BUCKETS` |
| `_METRICS_CONTENT_TYPE` | Same | `METRICS_CONTENT_TYPE` |
| `free!` (Manager) | Should it be exported? It's internal | `free!` or rename to `close!` |
| `init_tty!` | Not exported, fine | Keep |
| `_tostring` | Duplicates `to_string` in adapter.jl | Remove, use `to_string` |
| `_Wildcard` | Type name — Julia uses CamelCase | `WildcardSentinel` |
| `cfunc_async` / `cfunc_sync` | Should follow function naming | Keep (they generate C function pointers) |
| `ws_touch!` | Good ✅ | Keep |
| `ws_register!` | Good ✅ | Keep |
| `_make_png` (example) | Fine for local helper | Keep |

### 3.2 Dead Code

Files included by the main module but potentially shadowed or unused:
- `src/core/` — entire directory (7 files, ~970 lines) appears to be a stale copy
- `src/http/` — 3 files (~740 lines) duplicating transport handler logic
- `src/servers/` — 2 files (~315 lines) duplicating server/ directory
- `src/ws/` — 3 files (~339 lines) duplicating transport/ws_handler.jl

**Total dead code: ~2,364 lines (30% of source)**

### 3.3 Thread Safety Concerns

1. `ServerCore.ws_clients::Dict{Int,WsConn}` — accessed from both event loop and worker threads without synchronization (in Async mode, event loop writes, workers could read via `invoke_ws`)
2. `ServiceRegistry.instances` — double-checked locking pattern is correct but uses `ReentrantLock` which allocates on contention
3. `RateLimit` shards use `SpinLock` correctly but `collect(shard.tracker)` during cleanup allocates under the lock

---

## 4. Proposed Architecture (v1.0)

### 4.1 Layered Architecture

```
┌─────────────────────────────────────────────────────┐
│  Application Layer (user code)                       │
│  - Route handlers, business logic                    │
├─────────────────────────────────────────────────────┤
│  Framework Layer                                     │
│  ┌─────────┐  ┌──────────┐  ┌───────────────────┐  │
│  │ Router  │  │Middleware │  │ Request/Response  │  │
│  │ (Trie)  │  │ Pipeline  │  │ (Typed, Struct)   │  │
│  └─────────┘  └──────────┘  └───────────────────┘  │
├─────────────────────────────────────────────────────┤
│  Server Layer                                        │
│  ┌──────────────────┐  ┌────────────────────────┐   │
│  │ ServerConfig     │  │ Lifecycle (start/stop) │   │
│  │ (immutable data) │  │ (state machine)        │   │
│  └──────────────────┘  └────────────────────────┘   │
├─────────────────────────────────────────────────────┤
│  Transport Layer (pluggable)                         │
│  ┌───────────────────────────────────────────────┐  │
│  │ MongooseTransport (default - C FFI)           │  │
│  │ Future: PureJuliaTransport, MockTransport     │  │
│  └───────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────┤
│  FFI Layer (Mongoose C bindings)                     │
└─────────────────────────────────────────────────────┘
```

### 4.2 Key Design Changes

#### A. Structured Response Headers

```julia
# Before (v0.3):
Response(200, "Content-Type: application/json\r\nX-Custom: val\r\n", body)

# After (v1.0):
struct Response
    status::Int
    headers::ResponseHeaders  # Dict-like, O(1) lookup, lazy serialization
    body::Union{String, Vector{UInt8}}
end

Response(200, body; content_type="application/json", headers=["X-Custom" => "val"])
```

#### B. Automatic JSON handling with typed routes

```julia
# FastAPI-style route definitions:
struct CreateUser
    name::String
    email::String
    age::Int
end

struct UserResponse
    id::Int
    name::String
    email::String
end

route!(router, :post, "/users", CreateUser => UserResponse) do req, body::CreateUser
    user = create_user(body)
    UserResponse(user.id, user.name, user.email)  # Auto-serialized to JSON
end
```

#### C. Route-level dependencies (like FastAPI's `Depends`)

```julia
# Define dependencies as functions
function get_db(req::Request)
    service(req, :database)
end

function get_current_user(req::Request)
    token = get(req.headers, "authorization", "")[8:end]
    find_user_by_token(token) || throw(HTTPException(401, "Invalid token"))
end

# Use in routes:
route!(router, :get, "/users/me", depends=[get_current_user]) do req, user
    Response(Json, user)
end
```

#### D. Exception handlers

```julia
struct HTTPException <: Exception
    status::Int
    detail::String
    headers::Vector{Pair{String,String}}
end

# Register exception handlers
on_error!(server, ValidationError) do req, exc
    Response(Json, Dict("detail" => exc.errors); status=422)
end

on_error!(server, HTTPException) do req, exc
    Response(Json, Dict("detail" => exc.detail); status=exc.status)
end
```

#### E. Pluggable transport

```julia
abstract type AbstractTransport end

struct MongooseTransport <: AbstractTransport
    manager::Manager
    c_handler::Ptr{Cvoid}
end

# Future:
struct PureJuliaTransport <: AbstractTransport
    server::Sockets.TCPServer
end

# Server is transport-agnostic:
server = Async(router; transport=MongooseTransport())
```

### 4.3 Simplified Module Structure (v1.0)

```
src/
├── Mongoose.jl              # Module root — clean exports only
├── types.jl                 # All public types (Request, Response, Headers, etc.)
├── config.jl                # Config, TLSConfig
├── errors.jl                # HTTPException, error hierarchy
├── ffi/                     # C bindings (unchanged)
│   ├── bindings.jl
│   ├── constants.jl
│   └── structs.jl
├── router/                  # Routing
│   ├── router.jl            # Router struct + route!
│   ├── trie.jl              # Trie implementation (internal)
│   ├── groups.jl            # Route groups
│   └── static.jl            # @router macro (AOT)
├── middleware/              # Middleware
│   ├── pipeline.jl          # AbstractMiddleware + execute
│   ├── cors.jl
│   ├── ratelimit.jl
│   ├── auth.jl
│   ├── logger.jl
│   ├── health.jl
│   ├── metrics.jl
│   ├── security.jl
│   └── compression.jl       # NEW: gzip/deflate
├── server/                  # Server
│   ├── server.jl            # Server + Async structs
│   ├── lifecycle.jl         # start!, shutdown!, state machine
│   └── workers.jl           # Worker pool (Async)
├── transport/               # Transport (pluggable)
│   └── mongoose/
│       ├── transport.jl     # MongooseTransport
│       ├── adapter.jl       # FFI → Request conversion
│       ├── connection.jl    # send_response!, send_ws!
│       ├── events.jl        # C callback dispatch
│       └── registry.jl      # GC-safe server lookup
├── ws/                      # WebSocket
│   ├── types.jl             # WsConn, Message, WsEndpoint
│   └── handler.jl           # WS event handling
├── streaming/               # SSE
│   └── sse.jl
├── parsing/                 # NEW: Request parsing
│   ├── json.jl              # JSON body parsing
│   ├── form.jl              # Form/multipart parsing
│   ├── query.jl             # Typed query parsing
│   └── validation.jl        # Input validation
└── util/                    # Utilities
    ├── log.jl
    └── strings.jl
```

---

## 5. Performance Considerations

### 5.1 Current Hot Path Analysis

The HTTP request hot path (`C event → Response → send`) involves:
1. C callback fires → `lookup_server` (Dict lookup + SpinLock)
2. `MgHttpMessage` construction (pointer load from C)
3. `preprocess_http` → `adapt_request` (allocates: String headers, Dict query, Request struct)
4. `execute_pipeline` (N closure allocations for middleware chain)
5. `dispatch_route` (Dict lookup or trie traversal)
6. User handler (allocates Response)
7. `send_http_response!` (formats response string, C call)

### 5.2 Optimization Opportunities

| Optimization | Expected Impact | Complexity |
|-------------|-----------------|------------|
| Arena allocator for per-request allocations | 20-30% throughput | High |
| Pre-allocated middleware chain (avoid closure per request) | 5-10% | Medium |
| Response header pooling (avoid string concat) | 10-15% | Medium |
| Inline dispatch for common methods (GET/POST) | 2-5% | Low |
| Connection-level keep-alive buffer reuse | 15-20% | High |
| SIMD header name comparison | 3-5% | Medium |

### 5.3 Benchmark Targets

| Metric | Current (estimated) | Target v1.0 | FastAPI (uvicorn) |
|--------|--------------------:|------------:|------------------:|
| Simple JSON response (req/s) | ~50,000 | ~150,000 | ~30,000 |
| Parametric route (req/s) | ~40,000 | ~120,000 | ~25,000 |
| Middleware chain (5 deep) | ~30,000 | ~80,000 | ~20,000 |
| Static file (small) | ~60,000 | ~100,000 | ~40,000 |
| P99 latency (ms) | ~2ms | ~0.5ms | ~5ms |

---

## 6. Testing Strategy

### 6.1 Current Test Coverage Issues

- **Port conflicts:** Tests use hardcoded ports (8091-8214), causing race conditions
- **No unit test isolation:** Cannot test router/middleware without starting a server
- **No mocking:** Transport layer is not mockable
- **Missing tests:** SSE streaming, route groups, service registry, error responses, static router edge cases

### 6.2 Proposed Test Architecture

```
test/
├── runtests.jl           # Test runner with dynamic port allocation
├── testutils.jl          # Shared utilities, port allocator, mock transport
├── unit/                 # Pure unit tests (no network)
│   ├── router_test.jl
│   ├── middleware_test.jl
│   ├── request_test.jl
│   ├── response_test.jl
│   ├── pipeline_test.jl
│   ├── config_test.jl
│   └── parsing_test.jl
├── integration/          # Tests with real HTTP (dynamic ports)
│   ├── server_test.jl
│   ├── async_test.jl
│   ├── tls_test.jl
│   ├── websocket_test.jl
│   ├── static_test.jl
│   └── streaming_test.jl
└── e2e/                  # Full application tests
    └── api_test.jl
```

### 6.3 Coverage Target

| Module | Current (est.) | Target |
|--------|---------------:|-------:|
| Router (trie) | ~70% | 95% |
| Middleware (each) | ~60% | 90% |
| Server lifecycle | ~50% | 85% |
| WebSocket | ~30% | 80% |
| SSE/Streaming | ~20% | 80% |
| Error handling | ~40% | 90% |
| Config/validation | ~30% | 95% |
| **Overall** | **~45%** | **>85%** |

---

## 7. Recommendations Summary

### Critical (Do First)
1. **Remove dead code** — Delete `src/core/`, `src/http/`, `src/servers/`, `src/ws/`
2. **Unify HTTP handler** — Single `dispatch_http` function with strategy pattern for sync/async
3. **Structured Response headers** — Replace `String` with proper type
4. **JSON body parsing** — Built-in `parse_body(req, T)` with validation
5. **Fix test port conflicts** — Dynamic port allocation

### High Priority
6. **Route-level dependency injection** — `depends` keyword in `route!`
7. **Exception handler system** — Typed error handling with custom responses
8. **Request validation** — Return 422 with field-level errors
9. **Compression middleware** — gzip/deflate for dynamic responses
10. **Remove dead directories** — Clean module structure

### Medium Priority
11. **OpenAPI generation** — Auto-generate spec from route definitions
12. **Lifespan events** — `on_startup`, `on_shutdown` hooks
13. **Background tasks** — Fire-and-forget after response
14. **Form/multipart parsing** — File upload support
15. **Pluggable transport** — Abstract transport interface

### Low Priority
16. **Interactive docs** — Swagger UI at `/docs`
17. **CLI tool** — `mongoose serve` command
18. **Hot reload** — File watcher for development
19. **API versioning helpers** — Header/path-based versioning
20. **Connection pooling metrics** — Detailed transport stats

---

## 8. Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Breaking changes alienate users | Low (v0.3 = few users) | Clear migration guide |
| Performance regression from abstractions | Medium | Benchmark CI gate |
| C FFI instability during refactor | Low | Keep FFI layer frozen |
| Scope creep (trying to build everything) | High | Phased roadmap |
| Julia ecosystem compatibility | Low | Minimal dependencies |

---

## Appendix A: Comparison with Top Frameworks

| Feature | Mongoose.jl v0.3 | FastAPI | Actix-web | Gin | Express.js |
|---------|:-:|:-:|:-:|:-:|:-:|
| Typed routes | ✅ | ✅ | ✅ | ✅ | ❌ |
| Auto JSON | ❌ | ✅ | ✅ | ✅ | ❌ |
| Validation | ❌ | ✅ | ✅ | ✅ | ❌ |
| OpenAPI | ❌ | ✅ | ❌ | ✅ | ❌ |
| Middleware | ✅ | ✅ | ✅ | ✅ | ✅ |
| WebSocket | ✅ | ✅ | ✅ | ❌ | ✅ |
| SSE | ✅ | ✅ | ✅ | ✅ | ✅ |
| DI | ❌ | ✅ | ✅ | ❌ | ❌ |
| TLS | ✅ | ✅ | ✅ | ✅ | ✅ |
| Streaming | ✅ | ✅ | ✅ | ✅ | ✅ |
| Compression | ❌ | ✅ | ✅ | ✅ | ✅ |
| Testing utils | ❌ | ✅ | ✅ | ✅ | ✅ |
| Production metrics | ✅ | ❌ | ❌ | ❌ | ❌ |
| Health checks | ✅ | ❌ | ❌ | ❌ | ❌ |
| AOT compilation | ✅ | ❌ | ✅ | ✅ | ❌ |

---

## Appendix B: Lines of Code Breakdown

| Directory | Lines | Status |
|-----------|------:|--------|
| `src/` (active) | ~4,800 | Active |
| `src/core/` | ~970 | Dead |
| `src/http/` | ~740 | Dead |
| `src/servers/` | ~315 | Dead |
| `src/ws/` | ~339 | Dead |
| `test/` | ~2,615 | Active |
| **Total source** | **~7,164** | — |
| **Active source** | **~4,800** | — |
| **Dead code** | **~2,364 (33%)** | Should be deleted |
