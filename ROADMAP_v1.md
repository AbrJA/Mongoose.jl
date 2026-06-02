# Mongoose.jl v1.0 — Refactoring Roadmap

## Phase 1: Core Architecture Simplification (Breaking Changes)

### 1.1 Unified App Type
**Goal**: Replace `Server{R}` + `Async{R}` + `Config` with a single `App` type.

**Changes**:
- Remove `Server`, `Async`, `Config`, `ServerCore` types
- Create `App` struct with all configuration as keyword arguments
- `workers=0` means single-threaded (current `Server` behavior)
- `workers>0` means worker pool (current `Async` behavior)
- Remove parametric router type — always use dynamic `Router`

### 1.2 Remove @router Macro
**Goal**: Eliminate static router complexity. Precompilation of dynamic router is sufficient.

**Changes**:
- Remove `src/router/static.jl`
- Remove `StaticRouter` abstract type
- Remove `cfunc_sync`/`cfunc_async` per-type generation
- Single C callback function for all servers
- Keep the trie router as the one and only router

### 1.3 Structured Response Headers
**Goal**: Headers as `Vector{Pair{String,String}}` internally, serialized on send.

**Changes**:
- `Response` stores headers as `Vector{Pair{String,String}}`
- Add `header(resp, key)` accessor
- Lazy serialization in `send_http_response!`
- Middleware can inspect/modify headers

### 1.4 Response Helpers
**Goal**: FastAPI-style response constructors.

**Changes**:
- `json(data; status=200, headers=[])` — auto-serializes Dict/Vector/NamedTuple
- `html(content; status=200)`
- `text(content; status=200)`
- `redirect(url; status=302)`
- `stream(producer; content_type, status=200)`
- `sse(producer; headers=[])`

### 1.5 Method-Specific Route Registration
**Goal**: `get!(app, path, handler)` instead of `route!(app, :get, path, handler)`.

**Changes**:
- Export `get!`, `post!`, `put!`, `patch!`, `delete!`, `options!`, `head!`
- Keep `route!` as the generic form
- All take `(app_or_router, path, handler)`

---

## Phase 2: Naming & API Cleanup

### 2.1 Rename Exports
| Current | New | Notes |
|---------|-----|-------|
| `plug!` | `use!` | Standard middleware term |
| `mount!` (static) | `serve!` | Clarity: serves static files |
| `fail!` | `onerror!` | Describes behavior |
| `context!` | `ctx!` | Shorter |
| `serialize_cookie` | `bake` | Short, idiomatic |
| `parse_cookies` | `cookies` | Noun = getter |
| `register_group!` | `mount!` | Route group = prefix mount |
| `sse_response` | `sse` | Shorter |
| `event!` | `emit` | Doesn't mutate |
| `register!` | `provide!` | DI term |
| `service` | `inject` | DI term |

### 2.2 Internal Function Naming
- Remove `!` from non-mutating internal functions
- Use `snake_case` for all internal functions
- Keep functions short: max 2 words

---

## Phase 3: Middleware Enhancement

### 3.1 Context Object
```julia
struct Context
    request::Request
    app::App
    state::Dict{Symbol,Any}  # Per-request state
end
```
Middleware signature: `(ctx::Context, next) → Response`

### 3.2 Lifecycle Hooks
- `onstart!(app, callback)` — runs before server accepts connections
- `onstop!(app, callback)` — runs during graceful shutdown
- Hooks stored in `App`, executed in order

### 3.3 Path-Scoped Middleware
- `use!(app, middleware; paths=["/api"])` — already exists, keep it

---

## Phase 4: Missing Features

### 4.1 Form/Multipart Parsing
- Parse `application/x-www-form-urlencoded` body
- Parse `multipart/form-data` for file uploads
- `form(req)` → `Dict{String,String}`
- `files(req)` → `Vector{UploadedFile}`

### 4.2 JSON Body Parsing
- `json(req)` → parsed body (using JSON.jl or JSON3.jl)
- Automatic `Content-Type` detection

### 4.3 Background Tasks
- `background!(app, task)` — spawns after response sent
- Tied to server lifecycle (cleaned up on shutdown)

### 4.4 Redirect Helper
- `redirect(url; status=302, headers=[])`

### 4.5 Exception Handlers
```julia
onerror!(app, ErrorType) do req, error
    json(Dict("error" => string(error)); status=500)
end
```

---

## Phase 5: Testing & Quality

### 5.1 Test Coverage Target: >80%
- Unit tests for every public function
- Integration tests for all middleware
- Edge case tests (malformed input, timeouts, concurrent access)
- WebSocket stress tests
- Memory leak detection tests

### 5.2 Test Utilities
- `testapp()` — creates an app with a free port
- `request(app, method, path; ...)` — in-process request (no HTTP overhead)

---

## Phase 6: Documentation & Examples

### 6.1 Production REST API Example
- CRUD operations with JSON
- Authentication (Bearer + API key)
- Rate limiting
- CORS
- Health checks
- Metrics
- Error handling
- File upload
- SSE streaming
- WebSocket chat

### 6.2 README
- Quick start (5 lines)
- Feature comparison table
- Performance benchmarks
- Migration guide from v0.x

### 6.3 API Documentation
- Docstrings for all public functions
- Usage examples in each docstring
- Documenter.jl site

---

## Implementation Order

```
Week 1: Phase 1 (Core refactor)
  ├─ 1.1 App type + remove Server/Async/Config
  ├─ 1.2 Remove @router macro
  ├─ 1.3 Structured response headers
  ├─ 1.4 Response helpers
  └─ 1.5 Method-specific routes

Week 2: Phase 2 + 3 (API + Middleware)
  ├─ 2.1 Rename all exports
  ├─ 2.2 Internal naming cleanup
  ├─ 3.1 Context object
  ├─ 3.2 Lifecycle hooks
  └─ 3.3 Verify path-scoped middleware

Week 3: Phase 4 (Features)
  ├─ 4.1 Form/multipart parsing
  ├─ 4.2 JSON body parsing
  ├─ 4.3 Background tasks
  ├─ 4.4 Redirect helper
  └─ 4.5 Exception handlers

Week 4: Phase 5 + 6 (Testing + Docs)
  ├─ 5.1 Comprehensive test suite
  ├─ 5.2 Test utilities
  ├─ 6.1 Production example
  ├─ 6.2 README rewrite
  └─ 6.3 API docs
```

---

## Breaking Changes Summary

| Removed | Replacement |
|---------|-------------|
| `Server(router; kwargs...)` | `App(; workers=0, kwargs...)` |
| `Async(router; kwargs...)` | `App(; workers=4, kwargs...)` |
| `Config(...)` | Direct kwargs to `App()` |
| `@router` macro | Use `Router()` with precompilation |
| `StaticRouter` | Removed |
| `plug!(server, mw)` | `use!(app, mw)` |
| `mount!(server, dir)` | `serve!(app, dir)` |
| `fail!(server, code, resp)` | `onerror!(app, code, handler)` |
| `serialize_cookie(c)` | `bake(c)` |
| `parse_cookies(req)` | `cookies(req)` |
| `register_group!(router, g)` | `mount!(app, group)` |
| `sse_response(f)` | `sse(f)` |
| `event!(sse; ...)` | `emit(sse; ...)` |
| `register!(reg, k, v)` | `provide!(app, k, v)` |
| `service(req, k)` | `inject(req, k)` |
| `context!(req)` | `ctx!(req)` |
| `Response(Format, body)` | `json(body)`, `html(body)`, `text(body)` |

---

## Non-Breaking Improvements
- Fix CORS `Vary: Origin` header
- Fix middleware execution for static routers (no longer exists)
- Improve error messages
- Add request ID to all responses by default
- Add graceful shutdown signal handling
- Improve precompilation workload
