# Mongoose.jl v1.0 — Implementation Roadmap

## Phase 1: Clean Foundation (Breaking Changes)

**Goal:** Remove dead code, fix naming, establish clean architecture base.

### 1.1 Remove Dead Code
- [ ] Delete `src/core/` directory (stale server/lifecycle copy)
- [ ] Delete `src/http/` directory (stale handler copy)
- [ ] Delete `src/servers/` directory (stale server copy)
- [ ] Delete `src/ws/` directory (stale websocket copy)
- [ ] Remove any remaining references to deleted files
- [ ] Verify `Mongoose.jl` only includes active source files

### 1.2 Standardize Naming Conventions
- [ ] Rename `_Wildcard` → `WildcardSentinel`
- [ ] Remove duplicate `_tostring` (use `to_string` from adapter.jl)
- [ ] Audit all exported functions for Julia convention compliance
- [ ] Ensure all mutating functions end with `!`
- [ ] Remove leading `_` from module-level constants that are internal but visible

### 1.3 Unify HTTP Handler
- [ ] Create single `dispatch_request!(server, conn, req)` strategy
- [ ] `Server` dispatches inline (sync)
- [ ] `Async` enqueues to channel
- [ ] Remove duplicate `on_http_message` implementations
- [ ] Single `preprocess_http` → `dispatch_request!` flow

### 1.4 Fix Test Infrastructure
- [ ] Create dynamic port allocator (atomic counter from 10000+)
- [ ] Replace all hardcoded ports in tests
- [ ] Add `@testset` isolation with proper server cleanup
- [ ] Fix WebSocket port conflicts

---

## Phase 2: Structured Types (Breaking Changes)

**Goal:** Replace stringly-typed headers with proper types, improve Response.

### 2.1 ResponseHeaders Type
- [ ] Create `ResponseHeaders` struct (ordered Dict-like, lazy serialization)
- [ ] `Base.setindex!`, `Base.getindex`, `Base.haskey` for headers
- [ ] Lazy `serialize(h::ResponseHeaders)::String` for FFI boundary
- [ ] Cache serialized form (invalidate on mutation)
- [ ] Update all middleware to use new headers

### 2.2 Improved Response Constructors
- [ ] `Response(status; body, content_type, headers)` — keyword-based
- [ ] `json(data; status=200)` — shorthand for JSON responses
- [ ] `html(body; status=200)` — shorthand for HTML
- [ ] `text(body; status=200)` — shorthand for plain text
- [ ] `redirect(url; status=302)` — redirect helper
- [ ] Keep `Response(Plain, body)` format style as secondary API

### 2.3 HTTPException System
- [ ] Define `HTTPException <: Exception` with status, detail, headers
- [ ] Define `ValidationError <: HTTPException` with field-level errors
- [ ] `on_error!(server, ExceptionType, handler)` registration
- [ ] Default handlers: 404, 405, 422, 500
- [ ] Structured JSON error responses by default

---

## Phase 3: Request Parsing & Validation

**Goal:** Automatic JSON parsing, typed query params, input validation.

### 3.1 JSON Body Parsing
- [ ] `parse_body(req, T)` → parses JSON body into struct T
- [ ] Returns `ValidationError` on parse failure (not crash)
- [ ] Support nested structs
- [ ] Support `Union{T, Nothing}` for optional fields

### 3.2 Typed Query Parameters
- [ ] `parse_query(req, T)` → typed query extraction
- [ ] Default values from struct defaults
- [ ] Automatic type conversion (String → Int, Bool, etc.)
- [ ] Validation errors with field names

### 3.3 Route-Level Body Type (FastAPI-style)
- [ ] `route!(router, :post, "/users", handler; body=CreateUser)`
- [ ] Auto-parse body before handler call
- [ ] Handler receives `(req, body::CreateUser)` signature
- [ ] 422 on validation failure with detailed error

### 3.4 Cookie Parsing on Request
- [ ] `parse_cookies(req)` → `Dict{String,String}`
- [ ] `get_cookie(req, name)` → `Union{String,Nothing}`
- [ ] Lazy parsing (only when accessed)

---

## Phase 4: Dependency Injection

**Goal:** Route-level DI system inspired by FastAPI's `Depends()`.

### 4.1 Dependency Protocol
- [ ] `Dependency` type wrapping a function `(Request) → T`
- [ ] Dependencies can depend on other dependencies (DAG resolution)
- [ ] Dependencies are cached per-request (call once, reuse result)
- [ ] Dependency errors → 401/403/422 responses automatically

### 4.2 Route Registration with Dependencies
- [ ] `route!(router, :get, "/users/me", handler; depends=[get_current_user])`
- [ ] Handler receives resolved dependencies as extra arguments
- [ ] Dependencies resolved before middleware chain (configurable)

### 4.3 Common Dependencies
- [ ] `current_user(validator)` — extract and validate auth token
- [ ] `pagination(; default_limit=20, max_limit=100)` — parse pagination params

---

## Phase 5: Production Features

**Goal:** Compression, background tasks, lifespan events.

### 5.1 Response Compression
- [ ] `compression()` middleware — gzip/deflate for responses > threshold
- [ ] Respect `Accept-Encoding` header
- [ ] Skip for already-compressed content types
- [ ] Configurable min size threshold (default: 1KB)

### 5.2 Lifespan Events
- [ ] `on_startup!(server, callback)` — called after bind, before accepting
- [ ] `on_shutdown!(server, callback)` — called during graceful shutdown
- [ ] Error in startup → server doesn't start

### 5.3 Background Tasks
- [ ] `background!(req, task_fn)` — schedule work after response sent
- [ ] Tasks run on separate task pool
- [ ] Error handling for background tasks (logging, not crashing)

### 5.4 Per-Route Configuration
- [ ] `route!(router, :post, "/upload", handler; max_body=50_000_000)`
- [ ] `route!(router, :get, "/slow", handler; timeout=30_000)`

---

## Phase 6: Testing & Quality

**Goal:** >85% test coverage, production-ready test suite.

### 6.1 Unit Tests (No Network)
- [ ] Router: all route patterns, edge cases, conflicts
- [ ] Middleware: each middleware in isolation
- [ ] Request/Response: construction, serialization, headers
- [ ] Pipeline: ordering, short-circuit, error propagation
- [ ] Config: validation, defaults, edge cases
- [ ] Parsing: JSON, query, cookies, validation errors

### 6.2 Integration Tests
- [ ] Server lifecycle: start, stop, restart, double-start
- [ ] HTTP: all methods, status codes, headers, body types
- [ ] WebSocket: connect, message, close, idle timeout
- [ ] TLS: certificate loading, HTTPS requests
- [ ] Static files: serve, 404, MIME types
- [ ] Streaming: SSE events, chunked transfer
- [ ] Concurrency: parallel requests, worker pool exhaustion, 503 backpressure

### 6.3 Test Utilities
- [ ] `with_server(config) do server ... end` — auto-cleanup
- [ ] Dynamic port allocation
- [ ] Proper test isolation

---

## Phase 7: Documentation & Examples

**Goal:** FastAPI-quality documentation with comprehensive examples.

### 7.1 README Rewrite
- [ ] Quick start (5 lines to working server)
- [ ] Feature comparison table
- [ ] Performance benchmarks
- [ ] Migration guide from v0.3

### 7.2 Production REST API Example
- [ ] Full CRUD API with typed bodies
- [ ] Authentication (JWT-style bearer)
- [ ] Input validation with error responses
- [ ] Pagination, filtering, sorting
- [ ] SSE endpoint (live updates)
- [ ] WebSocket chat endpoint
- [ ] Health/metrics/readiness endpoints
- [ ] CORS, rate limiting, security headers
- [ ] Environment-based configuration

---

## Phase 8: Future (Post v1.0)

- [ ] OpenAPI/Swagger auto-generation
- [ ] Swagger UI at `/docs`
- [ ] HTTP/2 support
- [ ] WebSocket pub/sub (rooms/channels)
- [ ] Distributed tracing (OpenTelemetry)
- [ ] Hot reload for development
- [ ] CLI tool

---

## Breaking Changes Summary

| Change | Migration |
|--------|-----------|
| Response headers now `ResponseHeaders` (not `String`) | Use `Response(200, body; headers=...)` |
| Dead code directories removed | None (were never loaded) |
| Middleware signature `(req, next)` only | Remove `params` argument |
| `_Wildcard` → `WildcardSentinel` | Internal only |

---

## Success Criteria for v1.0

- [ ] All tests pass (0 failures)
- [ ] Test coverage > 85%
- [ ] No dead code in source tree
- [ ] All naming follows Julia conventions
- [ ] JSON body parsing works out of the box
- [ ] Exception handling with structured errors
- [ ] Compression middleware included
- [ ] Production REST API example runs cleanly
- [ ] Documentation builds without warnings
- [ ] README at parity with FastAPI quality
