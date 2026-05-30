# Mongoose.jl — Technical Review & Production Readiness Report

> Date: May 2026 | Version: 0.3.1 | Julia 1.12+

---

## Executive Summary

Mongoose.jl is a high-performance HTTP server framework wrapping the C Mongoose library via FFI. It provides a batteries-included approach with routing, middleware, WebSocket, SSE, TLS, and AOT compilation support. However, several architectural decisions limit its ability to compete with production frameworks like Python's FastAPI or Rust's Axum.

**Current state:** Functional prototype with ~352 passing tests (~60-65% code coverage). Good performance characteristics from the C event loop but significant coupling, missing features, and design gaps prevent production use.

**Key findings:**
- 🔴 **Critical:** Duplicate router implementations (trie.jl vs dynamic.jl) create confusion
- 🔴 **Critical:** No request validation, no OpenAPI, no typed responses
- 🟡 **Major:** Transport layer tightly coupled to server internals
- 🟡 **Major:** Streaming blocks the event loop in Async mode
- 🟡 **Major:** No response compression, no multipart/form parsing
- 🟢 **Strength:** AOT compilation via `@router` macro
- 🟢 **Strength:** Built-in operational middleware (metrics, health, security)
- 🟢 **Strength:** Worker pool with supervision

---

## 1. Architecture Analysis

### 1.1 Current Layer Stack

```
┌─────────────────────────────────────────────────────────────┐
│  User API (route!, plug!, start!, shutdown!)                │
├─────────────────────────────────────────────────────────────┤
│  Middleware Pipeline (onion model)                           │
├─────────────────────────────────────────────────────────────┤
│  Router (Trie-based / Static @router)                       │
├─────────────────────────────────────────────────────────────┤
│  Protocol Layer (Request, Response, Headers, Cookie)        │
├─────────────────────────────────────────────────────────────┤
│  Transport (HTTP handler, WS handler, Connection)           │
├─────────────────────────────────────────────────────────────┤
│  Server Core (ServerCore, Manager, Registry)                │
├─────────────────────────────────────────────────────────────┤
│  FFI Layer (C structs, bindings, constants)                 │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Request/Response Flow

```
C mongoose mg_mgr_poll()
    │
    ▼
c_event_callback(conn, ev, ev_data)     ← SpinLock on REGISTRY
    │
    ▼ MG_EV_HTTP_MSG
preprocess_http(server, conn, ev_data)
    ├─ WS upgrade check
    ├─ Body size check (413)
    ├─ Static file check
    └─ adapt_request(msg) → Request
            │
            ▼
invoke_http(server, req)
    │
    ▼
execute_pipeline(middlewares, req, final_handler)
    │ Recursive closure chain: mw₁(req, () -> mw₂(req, () -> ...))
    ▼
dispatch_to_handler(router, req)
    ├─ Fixed routes (Dict O(1))
    ├─ Trie traversal (parametric)
    └─ Wildcard fallback
            │
            ▼
handler(req, params...) → Response | StreamResponse
    │
    ▼
send_http_response!(conn, response)     ← mg_http_reply / mg_send
```

### 1.3 Type Hierarchy

```
AbstractServer
├── Server{R}       — single-threaded, blocking event loop
└── Async{R}        — multi-threaded, worker pool + Channel

AbstractRouter
├── Router          — runtime trie-based, dynamic route registration
└── StaticRouter    — compile-time @router macro, AOT-safe

AbstractMiddleware
├── PathFilter      — path-prefix scoping wrapper
├── Cors            ├── Bearer
├── RateLimit       ├── ApiKey
├── Logger          ├── Health
├── SecurityHeaders └── PrometheusMetrics

AbstractFormat
├── Plain, Html, Css, Js, Json, Xml, Binary
```

---

## 2. Coupling & Design Issues

### 2.1 Critical: Duplicate Router Implementation

**Files:** `src/router/trie.jl` + `src/router/dynamic.jl`

Both define `Router`, `MethodMap`, `TrieNode` with slightly different field names and APIs. The `dynamic.jl` file appears to be dead code (shadowed by later includes). This creates confusion for contributors and IDE tooling.

**Impact:** Cannot safely refactor router without understanding which file is actually loaded.

### 2.2 Transport → Server Coupling

The HTTP handler (`src/transport/mongoose/http_handler.jl`) directly accesses:
- `server.core.middlewares`
- `server.core.router`
- `server.core.mounts`
- `server.core.services`
- `server.core.errors`
- `server.core.id_seq`

This makes it impossible to swap transport implementations without rewriting the handler.

**Fix:** Define a `ServerInterface` trait/protocol that the transport layer calls through.

### 2.3 Monolithic ServerCore

`ServerCore{R}` holds 16+ fields mixing:
- Lifecycle state (`running`, `master`, `manager`)
- Configuration (`poll_timeout`, `max_body`, etc.)
- Runtime state (`ws_clients`, `id_seq`)
- Application logic (`router`, `middlewares`, `mounts`, `errors`, `services`)

**Impact:** Adding any new feature requires modifying the core type. Configuration, runtime state, and application concerns are not separated.

### 2.4 Streaming Blocks Event Loop

In `Async` mode, `StreamResponse` is written on the event loop thread:
```julia
# src/server/async.jl line 111-112
try send_stream_response!(conn, reply.payload) catch e; ... end
```
This blocks ALL other connections for the duration of the stream, defeating the purpose of async architecture.

### 2.5 Global Mutable State

- `REGISTRY` + `REGISTRY_LOCK` in `server/registry.jl`
- Rate limit shards with `Dict` state
- Logger's `LOG_BACKEND` and `LOG_TRIMMABLE` globals

While some globals are necessary for C callback recovery, they prevent running multiple independent server instances in tests and make unit testing harder.

### 2.6 Response Header String Format

Responses use raw header strings: `Response(200, "Content-Type: text/plain\r\n", "body")`. This is:
- Error-prone (missing `\r\n`, wrong format)
- Not composable (middleware can't easily add/remove headers)
- Not inspectable (can't query response headers programmatically)

---

## 3. Missing Production Features

### 3.1 Request Validation & Schema (Priority: P0)

FastAPI's killer feature. Mongoose.jl has zero validation:
```julia
# Current: manual, unsafe
route!(router, :post, "/users") do req
    data = JSON.parse(req.body)  # Can throw on invalid JSON
    name = data["name"]          # Can throw on missing key
    age = data["age"]            # No type checking
end
```

**Needed:**
- Schema definitions (via Julia types or macros)
- Automatic JSON deserialization with type checking
- Validation error responses (422 with detailed messages)
- Path/query parameter type coercion with validation

### 3.2 OpenAPI/Swagger Auto-generation (Priority: P1)

No documentation generation exists. This is table-stakes for production APIs.

**Needed:**
- Route metadata (description, tags, deprecation)
- Request/response schema export to OpenAPI 3.1
- Swagger UI endpoint (`/docs`)
- ReDoc endpoint (`/redoc`)

### 3.3 Response Serialization (Priority: P0)

Currently manual: `Response(Json, JSON.json(data))`.

**Needed:**
- Auto-serialization from Julia types
- Content negotiation (Accept header)
- Response type declarations for docs

### 3.4 Form/Multipart Parsing (Priority: P1)

Not implemented. Cannot handle file uploads or HTML form submissions.

### 3.5 Response Compression (Priority: P1)

No gzip/deflate/brotli support. Modern APIs compress by default.

### 3.6 Background Tasks (Priority: P2)

No way to fire-and-forget tasks after sending a response:
```julia
# FastAPI equivalent needed:
route!(router, :post, "/email") do req
    # ... validate
    background!(send_email, req.body)  # runs after response sent
    Response(202, "", "accepted")
end
```

### 3.7 Dependency Injection (Priority: P1)

`ServiceRegistry` exists but is a simple key-value store. No:
- Per-route dependencies
- Dependency resolution graph
- Scoped lifetimes (request, application)
- Lazy initialization

### 3.8 Testing Utilities (Priority: P1)

No `TestClient` abstraction:
```julia
# Needed:
client = TestClient(app)
resp = client.get("/users")
@test resp.status == 200
```

Currently requires starting a real server and making HTTP requests.

### 3.9 HTTP/2 Support (Priority: P3)

The C mongoose library is HTTP/1.1 only. Not blocking for v1.0 but needed long-term.

### 3.10 Inbound Body Streaming (Priority: P2)

Request body is fully buffered before handler runs. Large file uploads will OOM.

---

## 4. Performance Concerns

### 4.1 Middleware Closure Chain

`_build_chain` creates one closure per middleware per request:
```julia
next = () -> _build_chain(middlewares, req, handler, idx + 1)
```
With 5 middleware, that's 5 heap allocations per request. Under 100k req/s, this creates significant GC pressure.

**Fix:** Pre-compile the chain at plug! time as a single typed function, or use a flat loop with before/after hooks.

### 4.2 SpinLock on Every C Callback

Every event (including high-frequency WS pings, polls) acquires:
```julia
lock(REGISTRY_LOCK)
server = get(REGISTRY, id, nothing)
unlock(REGISTRY_LOCK)
```
Under high connection counts, this becomes contention hotspot.

**Fix:** Use `Threads.Atomic` pointer or `Base.@lock` with a ReentrantLock. Or, since the registry rarely changes, use a read-write lock pattern.

### 4.3 Vector{Any} for Route Parameters

Parametric route matches return `Any[]` (boxed params). Every parametric request allocates and boxes values.

**Fix:** Use tuples or type-stable containers. The `@router` macro already solves this for static routes.

### 4.4 Header Parsing Per Request

`parse_headers` allocates a new `Vector{Pair{String,String}}` for every request:
```julia
pairs = Pair{String,String}[]
sizehint!(pairs, 12)
```

**Fix:** Pool `Vector` instances, or use a fixed-capacity stack-allocated buffer for common header counts.

### 4.5 Rate Limit Cleanup

`collect(shard.tracker)` copies the entire Dict for iteration during cleanup, creating a latency spike:
```julia
for (k, v) in collect(shard.tracker)  # allocates full copy
```

**Fix:** Use `filter!` in-place or maintain a sorted expiry index.

---

## 5. API Surface Issues

### 5.1 Inconsistent Configuration

Three ways to configure a server:
```julia
Server(router; max_body=1024)              # kwargs
Server(router, Config(max_body=1024))      # Config struct
Async(router; nworkers=4, max_body=1024)   # different kwargs per type
```

**Fix:** Single `Config` approach. Constructor takes `(router, config)` only.

### 5.2 Inconsistent Route Registration

```julia
route!(router, :get, "/path", handler)     # HTTP: symbol + path + handler
ws!(router, "/path"; on_message=handler)   # WS: path + kwargs
```

**Fix:** Unified interface: `route!(router, :get, "/path", handler)` and `route!(router, :ws, "/path", handler)`.

### 5.3 Response Constructor Overload

```julia
Response(Plain, "body")                    # format + body
Response(200, "", "body")                  # status + headers_str + body
Response(Plain, "body"; status=201)        # format + body + kwargs
Response(Plain, "body"; headers=[...])     # format + body + headers
```

Four different constructors with different semantics. The raw `(status, headers_string, body)` form is dangerous.

**Fix:** Remove raw constructor from public API. Use only: `Response(format, body; status, headers)`.

### 5.4 Naming Convention Violations

Julia convention: internal functions use lowercase with underscores, no leading `_` prefix (that's Python). Functions are named by what they do, not prefixed for visibility.

Current violations:
- `_build_chain`, `_is_pem`, `_is_path` → should be `build_chain`, `is_pem`, `is_path` (or unexported)
- `_PORT_COUNTER`, `_RATE_LIMIT_SHARDS` → should be `const PORT_COUNTER`, `const RATE_LIMIT_SHARDS`
- `_RateShard` → should be `RateShard` (not exported anyway)
- `_print_info`, `_print_warn`, `_print_error` → `print_info`, `print_warn`, `print_error`
- `_escape` → `escape_json_string`

Julia uses `!` suffix for mutating functions. Current conformance is good (`route!`, `plug!`, `start!`, `shutdown!`).

---

## 6. Security Audit

### 6.1 Header Injection

`sanitize_header_value` exists but is only used for X-Request-Id. Response headers created by user code are not sanitized:
```julia
Response(200, "X-Custom: $(user_input)\r\n", "body")  # CRLF injection possible
```

**Fix:** All header values must pass through sanitization before being sent.

### 6.2 Path Traversal in Static Files

Static file serving uses C `mg_http_serve_dir` which should handle traversal, but the Julia `mount!` configuration isn't validated:
```julia
mount!(server, "/", "../../../etc/")  # could expose filesystem
```

**Fix:** Validate and canonicalize mount paths. Reject `..` sequences.

### 6.3 Unbounded Request Body

While `max_body` exists, it's checked AFTER the full body is received from C:
```julia
if msg.body.len > server.core.max_body
    # Already in memory!
```

**Fix:** Configure C library's `MG_MAX_RECV_BUF_SIZE` to reject at the network layer.

### 6.4 No CSRF Protection

No built-in CSRF middleware for cookie-authenticated endpoints.

### 6.5 No Input Sanitization Middleware

No XSS prevention, SQL injection guards, or content security beyond response headers.

---

## 7. Comparison: Mongoose.jl vs FastAPI vs Axum

| Capability | FastAPI | Axum (Rust) | Mongoose.jl | Gap |
|:-----------|:-------:|:-----------:|:-----------:|:---:|
| Type-safe routing | ✅ | ✅ | ⚠️ | Medium |
| Request validation | ✅ (Pydantic) | ✅ (serde) | ❌ | Critical |
| OpenAPI auto-gen | ✅ | ✅ (utoipa) | ❌ | Critical |
| Dependency injection | ✅ | ✅ (extractors) | ⚠️ | High |
| Middleware (tower-like) | ✅ | ✅ | ✅ | - |
| Response serialization | ✅ | ✅ | ❌ | High |
| WebSocket | ✅ | ✅ | ✅ | - |
| SSE | ✅ | ✅ | ✅ | - |
| Multipart/forms | ✅ | ✅ | ❌ | High |
| Compression | ✅ | ✅ | ❌ | Medium |
| Testing client | ✅ | ✅ | ❌ | High |
| Error handling | ✅ | ✅ | ⚠️ | Medium |
| Background tasks | ✅ | ✅ (tokio) | ❌ | Medium |
| HTTP/2 | ✅ | ✅ | ❌ | Low (v2) |
| Graceful shutdown | ✅ | ✅ | ✅ | - |
| TLS | ✅ | ✅ | ✅ | - |
| Metrics/Health | ⚠️ (3rd) | ⚠️ (3rd) | ✅ | Advantage |
| AOT compilation | ❌ | ✅ | ✅ | Advantage |
| Worker pool | ⚠️ (uvicorn) | ✅ (tokio) | ✅ | - |
| Performance (rps) | ~50k | ~500k | ~200k* | - |

*Estimated based on C mongoose performance and Julia overhead.

---

## 8. Recommendations Summary

### Immediate (v0.4 — Breaking Changes OK)

1. **Remove duplicate router** — Delete `dynamic.jl`, keep `trie.jl` only
2. **Structured Response headers** — Change from raw string to `Vector{Pair{String,String}}`
3. **Standardize naming** — Remove `_` prefixes, follow Julia conventions
4. **Add `retry=false` default** — Document HTTP.jl v2 interaction for tests
5. **Fix streaming in Async** — Move stream writes to dedicated IO task

### Short-term (v0.5 — Core Features)

6. **Request body parsing** — JSON, form, multipart with type coercion
7. **Response serialization** — Auto JSON from Julia types
8. **TestClient** — In-process testing without network
9. **Compression middleware** — gzip/deflate
10. **Background tasks** — `background!(fn, args...)` API

### Medium-term (v0.6 — Production Polish)

11. **OpenAPI generation** — Route metadata → OpenAPI 3.1 spec
12. **Dependency injection** — Per-route extractors (like Axum)
13. **Typed responses** — Return type declarations for docs
14. **Error handler registry** — Exception type → Response mapping
15. **Connection pooling** — HTTP client for upstream calls

### Long-term (v1.0 — Feature Complete)

16. **HTTP/2 support** — Evaluate transport swap (h2o, hyper-rs)
17. **Plugin system** — Package-based extensions
18. **Hot reload** — Zero-downtime config/route changes
19. **Distributed tracing** — OpenTelemetry integration
20. **Admin dashboard** — Built-in server monitoring UI

---

## 9. Test Coverage Assessment

### Current: ~60-65% estimated

| Layer | Coverage | Priority to Fix |
|-------|----------|-----------------|
| Protocol (Request/Response/Cookie) | ~90% | Low |
| Middleware | ~75% | Medium |
| Router | ~70% | Medium |
| Server lifecycle | ~50% | **High** |
| Transport/FFI | ~45% | **High** |
| Utility functions | ~40% | Medium |
| Async worker pool | ~55% | **High** |
| WebSocket handling | ~45% | **High** |
| Streaming/SSE | ~75% | Medium |
| Error paths | ~25% | **Critical** |

### Untested Critical Paths

1. Body size rejection (413)
2. Queue full rejection (503) in Async
3. Request timeout enforcement
4. WS frame size limit enforcement
5. WS idle timeout sweep
6. Worker crash + supervisor respawn
7. Graceful drain under load
8. TLS material loading (PEM strings, invalid paths)
9. X-Request-Id injection/forwarding
10. Header sanitization (CRLF injection prevention)

---

## 10. Conclusion

Mongoose.jl has strong foundations — the C event loop gives excellent performance, the type hierarchy is clean, and the middleware pipeline is well-designed. However, to compete with FastAPI/Axum, it needs:

1. **A validation layer** (the single most impactful addition)
2. **Structured response headers** (enables middleware composition)
3. **Decoupled transport** (enables testing and alternative backends)
4. **OpenAPI generation** (table-stakes for production APIs)
5. **~95%+ test coverage** (especially error paths and edge cases)

The good news: the core architecture is sound. The fixes are mostly additive (new layers) rather than fundamental rewrites. The recommended approach is to build a thin `Extractors` layer (like Axum) that handles validation, parsing, and DI — leaving the existing transport/protocol stack largely intact.
