# Mongoose.jl — Comprehensive Code Review & Architecture Report

## Executive Summary

Mongoose.jl is a well-conceived lightweight HTTP server wrapping the Mongoose C library. The core functionality works, the router is cleverly designed, and the sync/async server model is a solid foundation. However, **the architecture has significant coupling and extensibility problems** that will make adding WebSocket support (or any new protocol/feature) very difficult. This report is a brutally honest assessment with concrete, actionable improvements.

---

## Overall Assessment

| Area | Score | Notes |
|---|---|---|
| **Correctness** | ⭐⭐⭐⭐ | Works for HTTP. Tests pass. |
| **Performance** | ⭐⭐⭐ | Good low-level tricks, but some unnecessary allocations |
| **Modularity** | ⭐⭐ | **Major issue.** Tight coupling everywhere |
| **Extensibility** | ⭐ | **Critical issue.** Adding WebSockets is nearly impossible |
| **Error Handling** | ⭐⭐ | Inconsistent; uses `error()` instead of proper exception types |
| **Type Safety** | ⭐⭐⭐ | Some good usage, but `Ptr{Cvoid}` everywhere weakens it |
| **Documentation** | ⭐⭐⭐ | README is good; docstrings are incomplete |
| **Test Coverage** | ⭐⭐⭐ | Tests cover happy paths but miss edge cases |

---

## 1. Architecture & Design Pattern Issues

### 1.1 The God-Module Anti-Pattern in [Mongoose.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/Mongoose.jl)

[Mongoose.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/Mongoose.jl) is doing too many things: it defines route registration logic, server lifecycle management, AND acts as the module entry point. This violates the Single Responsibility Principle.

**Problem**: The `route!` function (lines 26–63) and `start!/shutdown!` (lines 77–117) are defined directly in the main module file. This creates a monolithic entry point that will grow uncontrollably as you add features.

**Recommendation**: Move `route!` into [routes.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/routes.jl) and `start!/shutdown!` into [servers.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/servers.jl). The main module should ONLY contain `include()` calls, `export` statements, and constants.

### 1.2 Concrete Type Coupling — The #1 Blocker for WebSockets

This is the single biggest architectural problem. Your event handlers, server logic, and request/response types are all hardcoded to HTTP concepts:

```julia
# events.jl — Hardcoded to HTTP
function sync_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    ev == MG_EV_HTTP_MSG || return  # ← Can ONLY handle HTTP
    ...
end
```

```julia
# servers.jl — Worker loop hardcoded to HTTP request/response
function worker_loop(server::AsyncServer, worker_index::Integer, router::Router)
    request = take!(server.requests)         # ← IdRequest (HTTP-only)
    response = execute_handler(router, request)  # ← HTTP router only
    put!(server.responses, response)         # ← IdResponse (HTTP-only)
end
```

```julia
# servers.jl — Channels are typed to HTTP
requests::Channel{IdRequest}       # ← Can't put WebSocket frames here
responses::Channel{IdResponse}     # ← Can't put WebSocket messages here
```

**Why WebSockets are impossible to add**: Every layer from the C callback up to the worker loop is hardcoded to `IdRequest`/`IdResponse`. A WebSocket frame is fundamentally different from an HTTP request — it's bidirectional, stateful, and long-lived. You can't shoehorn it into the existing `Channel{IdRequest}` pipeline.

### 1.3 Global Mutable State — The `REGISTRY` Problem

[registry.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/registry.jl) uses a global `Dict{UInt,Server}`:

```julia
const REGISTRY = Dict{UInt,Server}()
```

**Problems**:
- **Not thread-safe**: Multiple threads can read/write simultaneously
- **Memory leak risk**: If `unregister!` is skipped (crash, exception), servers stay in `REGISTRY` forever
- **Testing pollution**: Tests share global state; one test's server bleeds into another
- **No key collision protection**: `objectid()` is not guaranteed unique for the lifetime of the process if objects are GC'd and new ones allocated at the same address

**Recommendation**: Use a `ReentrantLock`-protected registry, or better yet, eliminate the global by passing the server reference through the C callback `fn_data` more safely (see Section 3).

### 1.4 Missing Middleware/Pipeline Pattern

Every production HTTP framework has a middleware pipeline. Mongoose.jl has none. Without it, common cross-cutting concerns like logging, authentication, CORS, rate limiting, and compression all have to be manually implemented inside every handler.

**Current flow**:
```
C Callback → build_request → execute_handler → user handler → response
```

**Desired flow**:
```
C Callback → build_request → middleware₁ → middleware₂ → ... → user handler → response
```

---

## 2. File-by-File Detailed Analysis

### 2.1 [wrappers.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/wrappers.jl) — C FFI Layer

**Good**:
- Clean struct definitions matching C layout
- `to_string` handles NULL pointers correctly

**Issues**:

| Line | Issue | Severity |
|------|-------|----------|
| 1 | `using Mongoose_jll` duplicated (also in `Mongoose.jl:3`) | Minor |
| 7 | `MgConnection = Ptr{Cvoid}` — type alias hides the fact this is an opaque pointer | Medium |
| 6 | `MG_MAX_HTTP_HEADERS = 30` hardcoded — should come from the C library | Medium |
| 44-46 | `Base.unsafe_convert(Cstring, url)` — unnecessary; `ccall` auto-converts `String` to `Cstring` | Minor |

**Recommendations**:
- Remove the duplicate `using Mongoose_jll`
- Add WebSocket-related event constants (`MG_EV_WS_OPEN`, `MG_EV_WS_MSG`, `MG_EV_WS_CTL`) now, even if not used yet
- Create a proper wrapper type instead of `Ptr{Cvoid}`:

```julia
# Type-safe opaque pointer wrapper
struct MgMgr
    ptr::Ptr{Cvoid}
end
```

- Eliminate manual `Base.unsafe_convert` calls — Julia's `ccall` handles `String → Cstring` natively

### 2.2 [structs.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/structs.jl) — Request/Response Types

**Good**:
- `_method_to_symbol` is a clever branchless-by-length method parser
- `sizehint!` on headers dict

**Issues**:

| Issue | Severity |
|-------|----------|
| `Request` is immutable but `Dict` fields are mutable — misleading | Medium |
| `IdRequest`/`IdResponse` couples connection identity to the HTTP layer | High |
| `serialize` name conflicts with Julia's `Serialization.serialize` | Medium |
| `Response` has headers as `String` — prevents programmatic access after construction | Medium |
| No abstract type hierarchy for Request/Response | High |

**Critical Issue — `_method_to_symbol`**:

```julia
# Line 65-67: This is WRONG for edge cases
len == 3 && return :put   # What about "PRI" (HTTP/2 preface)?
len == 4 && return :post  # What about "PRXY" or other custom methods?
len == 5 && return :patch # Assumes all 5-letter P-methods are PATCH
```

The function shortcuts by length alone for 'P'-starting methods. While clever for the common case, it silently returns wrong results for non-standard HTTP methods. At minimum, verify the second character.

**Recommendation — Protocol-Agnostic Message Types**:

```julia
abstract type AbstractMessage end
abstract type AbstractRequest <: AbstractMessage end
abstract type AbstractResponse <: AbstractMessage end

struct HttpRequest <: AbstractRequest
    method::Symbol
    uri::String
    query::String
    headers::Dict{String,String}
    body::String
end

struct WsMessage <: AbstractMessage
    opcode::UInt8
    data::Vector{UInt8}
end
```

### 2.3 [routes.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/routes.jl) — Router

**Good**:
- Trie-based routing with static/dynamic segments is the right approach
- Backtracking in `_match` is correct
- `@inline` on the hot path

**Issues**:

| Issue | Severity |
|-------|----------|
| `Matched.handler` should be `handlers` (plural) — it stores a Dict | Minor |
| `_match` uses `split()` which allocates a `Vector{SubString}` on every request | Medium |
| `execute_handler` is in [routes.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/routes.jl) but depends on `IdRequest`/`IdResponse` from [structs.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/structs.jl) — circular coupling | Medium |
| No wildcard/glob route support (`/static/*filepath`) | Low |
| No route listing/introspection API | Low |
| `Fixed` struct is redundant — it's just `Dict{Symbol,Function}` with a wrapper | Minor |

**Performance Issue — Allocation per Request**:

```julia
# Line 33-34: Allocates on EVERY request
segments = split(path, '/'; keepempty=false)  # → Vector{SubString}
params = Dict{String,String}()               # → Dict allocation
```

For a high-performance framework, this matters. Consider using a stack-allocated approach or pre-split during route registration.

**Recommendation — Separate routing from HTTP response formation**:

```julia
# routes.jl should ONLY match routes, not create HTTP responses
function execute_handler(router::Router, method::Symbol, uri::String, request)
    matched = match_route(router, method, uri)
    matched === nothing && return nothing
    handler = get(matched.handlers, method, nothing)
    handler === nothing && return :method_not_allowed
    return handler(request, matched.params)
end
```

### 2.4 [events.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/events.jl) — C Event Callbacks

**This is the file that most needs redesigning for WebSocket support.**

**Issues**:

| Issue | Severity |
|-------|----------|
| Two separate `@cfunction` callbacks with duplicated logic | High |
| `select_server` looks up global `REGISTRY` on every single event | High (perf) |
| `build_request` is HTTP-specific but called from the generic event handler | High |
| No event type dispatch system | Critical |

**Current Design Problem**:

```julia
# Two nearly-identical functions
function sync_event_handler(conn, ev, ev_data)
    ev == MG_EV_HTTP_MSG || return
    server = select_server(conn)
    request = build_request(conn, ev_data)
    handle_request(conn, server, request)
end

function async_event_handler(conn, ev, ev_data)
    ev == MG_EV_POLL && return
    server = select_server(conn)
    ev == MG_EV_CLOSE && return cleanup_connection(conn, server)
    if ev == MG_EV_HTTP_MSG
        request = build_request(conn, ev_data)
        handle_request(conn, server, request)
    end
end
```

These two functions are the **chokepoint** blocking extensibility. When you add WebSockets, you'd need `MG_EV_WS_OPEN`, `MG_EV_WS_MSG`, `MG_EV_WS_CTL` handlers, and the current structure can't accommodate them without turning these functions into massive if/else chains.

**Recommendation — Event Dispatch Pattern**:

```julia
# Single unified callback with dispatch
function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    ev == MG_EV_POLL && return  # Fast exit for most common event
    server = select_server(conn)
    dispatch_event!(server, conn, ev, ev_data)
    return
end

# Multiple dispatch handles the rest
dispatch_event!(s::Server, conn, ev::Val{MG_EV_HTTP_MSG}, data) = handle_http!(s, conn, data)
dispatch_event!(s::Server, conn, ev::Val{MG_EV_WS_MSG}, data)  = handle_ws!(s, conn, data)
dispatch_event!(s::Server, conn, ev::Val{MG_EV_CLOSE}, data)    = handle_close!(s, conn)
dispatch_event!(s::Server, conn, ev, data) = nothing  # Fallback
```

> [!IMPORTANT]
> You can't use `Val{ev}` directly in a `@cfunction` because `ev` is only known at runtime. Instead, use a lookup table or `if/elseif` chain that dispatches to type-stable inner functions. The key insight is to separate **event routing** from **event handling**.

### 2.5 [servers.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/servers.jl) — Server Types

**Good**:
- Finalizer for cleanup
- Channel-based async architecture

**Issues**:

| Issue | Severity |
|-------|----------|
| `Manager` manually calls `Libc.malloc(Csize_t(128))` — magic number, assumes sizeof mg_mgr | Critical |
| `SyncServer` and `AsyncServer` share ~60% identical fields (DRY violation) | High |
| `@async` for master event loop — should be `Threads.@spawn` for true parallel execution | High |
| `cleanup_connection` takes `MgConnection` (alias for `Ptr{Cvoid}`) but the `Int()` conversion is fragile | Medium |
| `process_responses!` runs in event loop — if a handler is slow, response delivery is blocked | Medium |

**Critical Issue — Magic Number `128`**:

```julia
# Line 6: What is 128?
ptr = Libc.malloc(Csize_t(128))
```

This assumes the C `struct mg_mgr` is 128 bytes. If the Mongoose C library is updated and the struct size changes, this will cause **silent memory corruption**. This is a **production-breaking bug waiting to happen**.

**Recommendation**:

```julia
# Use sizeof from C or a generous upper bound with documentation
const MG_MGR_SIZE = 256  # Upper bound for mg_mgr struct; verified against Mongoose v7.x
ptr = Libc.malloc(Csize_t(MG_MGR_SIZE))
```

Or better yet, use `ccall` to ask the C side for the size, or allocate through a C helper function.

**Issue — `@async` vs `Threads.@spawn`**:

```julia
# Line 82: @async runs on the SAME thread as the caller
server.master = @async begin
    run_event_loop(server)
end
```

`@async` creates a cooperative `Task`, not an OS thread. This means the event loop and all Julia code share the same thread, co-operatively yielding. For a high-performance server, the event loop should run on its own OS thread:

```julia
server.master = Threads.@spawn begin
    run_event_loop(server)
end
```

**Issue — DRY Violation in Server Structs**:

```julia
# SyncServer has 6 fields, AsyncServer has 12
# They share: manager, handler, timeout, master, router, running
```

**Recommendation — Use composition**:

```julia
mutable struct ServerCore
    manager::Manager
    handler::Ptr{Cvoid}
    timeout::Cint
    master::Union{Nothing,Task}
    router::Router
    running::Bool
end

mutable struct AsyncServer <: Server
    core::ServerCore
    workers::Vector{Task}
    requests::Channel{IdRequest}
    responses::Channel{IdResponse}
    connections::Dict{Int,MgConnection}
    nworkers::Int
    nqueue::Int
end
```

### 2.6 [registry.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/registry.jl) — Global Server Registry

Already covered in Section 1.3. Additional issue: `shutdown!()` (no args) iterates `values(REGISTRY)` while also calling `shutdown!(server)` which calls `unregister!` — this mutates the dict during iteration. The `collect()` call saves it, but this is fragile.

### 2.7 [utils.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/utils.jl) — Serialization Utilities

**Good**:
- `@generated` function for struct deserialization is performant
- `decode_range` avoids unnecessary allocations by working on bytes

**Issues**:

| Issue | Severity |
|-------|----------|
| `deserialize` name conflicts with `Serialization.deserialize` | Medium |
| `deserialize` uses `dict[key]` — throws `KeyError` with no helpful message | Medium |
| No JSON parsing support (only query string and Dict) | Medium |
| `@generated` function doesn't handle `Optional` fields | Low |
| Missing `encode_range` / URL encoding counterpart | Low |

**Recommendation**: Use names like `from_query` / `to_headers` to avoid conflicts with Base/stdlib names.

---

## 3. Proposed Architecture for WebSocket Support

Here's a concrete design that solves the extensibility problem:

### 3.1 Protocol-Agnostic Event System

```
┌─────────────────────────────────────────────────────┐
│                   Mongoose C Library                 │
│              (mg_mgr_poll event loop)                │
└──────────────────────┬──────────────────────────────┘
                       │ @cfunction callback
                       ▼
┌─────────────────────────────────────────────────────┐
│              Event Dispatcher (events.jl)            │
│                                                      │
│   ev == MG_EV_HTTP_MSG  → handle_http!(server, ...)  │
│   ev == MG_EV_WS_OPEN   → handle_ws_open!(...)      │
│   ev == MG_EV_WS_MSG    → handle_ws_msg!(...)       │
│   ev == MG_EV_CLOSE      → handle_close!(...)        │
└──────────────────────┬──────────────────────────────┘
                       │ Multiple dispatch
                       ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  HTTP Layer  │  │   WS Layer   │  │ Future Proto │
│  routes.jl   │  │ websockets.jl│  │   mqtt.jl    │
│  handlers    │  │  handlers    │  │   etc.       │
└──────────────┘  └──────────────┘  └──────────────┘
```

### 3.2 Recommended File Structure

```
src/
├── Mongoose.jl          # Module entry only: includes, exports, constants
├── core/
│   ├── types.jl         # Abstract types & interfaces
│   ├── server.jl        # ServerCore, Manager, lifecycle
│   ├── registry.jl      # Thread-safe global registry
│   └── middleware.jl    # Middleware pipeline
├── ffi/
│   ├── bindings.jl      # All ccall wrappers
│   ├── structs.jl       # C struct mappings (MgStr, MgHttpMessage, MgWsMessage)
│   └── constants.jl     # Event constants, sizes
├── http/
│   ├── types.jl         # HttpRequest, HttpResponse
│   ├── router.jl        # Trie router
│   ├── handler.jl       # HTTP event handling
│   └── utils.jl         # URL decode, query parse, serialize
├── ws/                  # WebSocket module (future)
│   ├── types.jl
│   ├── handler.jl
│   └── connection.jl
└── servers/
    ├── sync.jl          # SyncServer
    └── async.jl         # AsyncServer
```

---

## 4. Performance Improvements

### 4.1 Allocation Hot Spots

| Location | Allocation | Fix |
|---|---|---|
| `routes.jl:33` | `split(path, '/')` → `Vector{SubString}` per request | Use `eachsplit()` (already used in `Mongoose.jl:37` for registration) |
| `routes.jl:34` | `Dict{String,String}()` per request for params | Use a small pre-allocated buffer or `Pair{String,String}[]` |
| `structs.jl:75` | `Dict{String,String}()` per request for headers | Consider lazy header parsing — only parse headers when accessed |
| `events.jl:4` | `MgHttpMessage(ev_data)` copies the entire message struct | This is unavoidable with `unsafe_load`, but consider if you need all fields |

### 4.2 Event Loop Optimization

```julia
# Current: yield() on every iteration — suboptimal
function run_event_loop(server::AsyncServer)
    while server.running
        mg_mgr_poll(server.manager.ptr, server.timeout)
        process_responses!(server)
        yield()  # ← Forces context switch even if there's work to do
    end
end
```

**Recommendation**: Use `timeout > 0` in `mg_mgr_poll` to let the C library handle blocking instead of busy-looping with `yield()`. When `timeout = 0`, you're effectively spin-locking.

### 4.3 Router Match Optimization

The current router allocates a `Dict` for params even on routes with no dynamic segments. For fixed routes, this is wasted:

```julia
# Line 30: Empty Dict allocated for fixed routes
return Matched(route.handlers, Dict{String,String}())
```

**Fix**: Use a sentinel empty Dict constant:

```julia
const EMPTY_PARAMS = Dict{String,String}()
# ... 
return Matched(route.handlers, EMPTY_PARAMS)
```

> [!WARNING]
> This is only safe if handlers never mutate the params dict. Document this contract clearly.

---

## 5. Error Handling & Safety

### 5.1 Custom Exception Types

Currently, errors are thrown with generic `error()`:

```julia
error("Invalid HTTP method: $method")
error("Failed to allocate manager memory")
error("Parameter conflict: :$param vs existing :$(dyn.param)")
```

**Recommendation**:

```julia
struct MongooseError <: Exception
    msg::String
end

struct RouteConflictError <: MongooseError
    path::String
    conflict::String
end

struct ServerError <: MongooseError
    msg::String
end
```

### 5.2 C Memory Safety

The `Manager` struct uses raw `Libc.malloc`:

```julia
ptr = Libc.malloc(Csize_t(128))
```

- No guarantee the allocation is zeroed out
- The magic number `128` is fragile
- No RAII pattern — relies on finalizer which may not run promptly

**Recommendation**: Use `Libc.calloc` (zero-initialized) and document the size requirement.

### 5.3 Thread Safety

The following shared mutable state is accessed without synchronization:

| State | Accessed From | Risk |
|---|---|---|
| `REGISTRY` (global Dict) | Event callbacks + user code | Race condition |
| `server.running` (Bool) | Master task + shutdown | Torn read (unlikely but UB) |
| `server.connections` (Dict) | Event loop + worker threads | Race condition |

**Recommendation**: Use `Threads.Atomic{Bool}` for `running`, `ReentrantLock` for `connections` and `REGISTRY`.

---

## 6. Missing Features for Production Readiness

| Feature | Priority | Difficulty |
|---|---|---|
| **Middleware pipeline** | Critical | Medium |
| **Structured logging** (log levels, formatting) | High | Low |
| **Graceful shutdown** (drain connections) | High | Medium |
| **Static file serving** | High | Low |
| **Request timeout** | High | Medium |
| **CORS middleware** | High | Low |
| **SSL/TLS support** (mongoose supports it) | High | Medium |
| **Health check endpoint** | Medium | Low |
| **Metrics/monitoring** hooks | Medium | Medium |
| **WebSocket support** | High | High (with current arch) / Medium (with proposed arch) |

---

## 7. Summary of Priority Actions

### 🔴 Critical (Do First)

1. **Fix the magic number `128` in `Manager`** — potential memory corruption
2. **Restructure event handling** — use a dispatch pattern instead of hardcoded `if/else`
3. **Add thread safety** to `REGISTRY`, `server.running`, and `server.connections`
4. **Use `Threads.@spawn` instead of `@async`** for the master event loop

### 🟡 High Priority (Design Improvements)

5. **Extract `route!` and `start!/shutdown!` from [Mongoose.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/Mongoose.jl)** into their respective files
6. **Introduce abstract type hierarchy** for messages (HTTP, WS, etc.)
7. **Add middleware pipeline** support to the router
8. **DRY the server structs** using composition (`ServerCore`)
9. **Rename `serialize`/`deserialize`** to avoid stdlib name conflicts

### 🟢 Nice to Have (Polish)

10. **Use `eachsplit` instead of `split`** in route matching for zero-alloc iteration
11. **Add constant `EMPTY_PARAMS`** to avoid allocating empty Dicts
12. **Improve `_method_to_symbol`** to verify beyond just length
13. **Add custom exception types**
14. **Expand test coverage** (edge cases, concurrent stress tests, error paths)

---

> [!TIP]
> The key insight is: **Julia's multiple dispatch is your best friend for extensibility**. Instead of `if ev == X ... elseif ev == Y`, define methods like `handle_event!(server, ::Val{MG_EV_HTTP_MSG}, conn, data)`. This lets users (and you) extend the framework by simply adding new method definitions — no modification of existing code required (Open/Closed Principle).
