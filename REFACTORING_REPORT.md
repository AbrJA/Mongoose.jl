# Refactoring Report

## Summary

This refactoring focused on **simplification, decoupling, and dead code removal** while maintaining full backward compatibility with the test suite (460/460 tests passing).

---

## Changes Made

### 1. Dead Code Removal
- **Deleted `src/router/dynamic.jl`** (245 lines) — an obsolete duplicate of `src/router/trie.jl` that was never included in the module.
- Dead directories (`src/core/`, `src/http/`, `src/servers/`, `src/ws/`) were already removed in a previous pass.

### 2. Centralized Service Injection
- **Before:** Service context (`ServiceRegistry`) was attached to requests in *both* `on_http_message(::Server)` and `on_http_message(::Async)` — duplicated code.
- **After:** Moved to `invoke_http()` (single point of responsibility). Both handlers are now simpler and the logic lives in one place.

### 3. Property Forwarding for Servers
- **Added `Base.getproperty`/`Base.setproperty!` on `AbstractServer`** that forwards core fields.
- Users can now write `server.router`, `server.middlewares`, `server.services` etc. instead of `server.core.router`.
- All internal code still uses `server.core.X` directly (no performance impact).

### 4. Ergonomic Response Constructor
- **Added `Response(status, body; headers=[...])`** — creates a response without requiring a format type.
- Useful for raw responses where the user manages Content-Type themselves.

### 5. Single-Point Validation
- **Moved `validate_core!` and `validate_errors!` into the `ServerCore` constructor.**
- Removed redundant validation from `Server()`, `Async()`, and `validate_config!()`.
- Now there's exactly one place where config values are validated — cleaner and impossible to bypass.

### 6. Exported `register_group!`
- Previously required `Mongoose.register_group!(router, group)`.
- Now exported directly: `register_group!(router, group)`.

---

## What Still Works

- All 460 tests pass (40.4s runtime)
- `@router` macro (AOT compilation) unchanged
- `Config` struct API unchanged
- All middleware unchanged
- WebSocket handling unchanged
- Static file serving unchanged
- TLS support unchanged

---

## Architecture After Refactoring

```
src/
├── ffi/           # C bindings (constants, structs, bindings)
├── util/          # Errors, strings, logging
├── protocol/      # Transport-agnostic types (Request, Response, formats, WS types, ServiceRegistry)
├── middleware/     # Pipeline + implementations (cors, auth, ratelimit, etc.)
├── router/        # Interface, static (@router), trie (dynamic), groups
├── transport/     # Mongoose C adapter (FFI→Julia, connection send, events, HTTP/WS handlers)
├── streaming/     # SSE support
└── server/        # Core types, lifecycle, sync/async modes, registry
```

**Key design principles maintained:**
- FFI boundary is crossed in exactly one place (`transport/mongoose/adapter.jl`)
- Middleware is composable and path-scopeable
- Server types are parametric on router type for specialization
- C callbacks are GC-safe via objectid registry

---

## What Can Still Be Simplified/Improved

### Short-term
1. **Response headers as structured type** — Currently `Response.headers` is a raw `String`. A `ResponseHeaders` wrapper (like `Headers` for requests) would make middleware header manipulation safer. Trade-off: breaking change to the most common type.
2. **Router `Vector{Any}` params** — Route parameters are boxed as `Any[]`. Typed tuples would eliminate boxing, but the current approach is pragmatic and simple.
3. **`_` prefix convention** — Some internal constants use `_` prefix (e.g., `_RATE_LIMIT_SHARDS`). This is non-standard Julia but harmless.

### Medium-term
4. **HTTP/2 and HTTP/3** — Mongoose C library is HTTP/1.1 only. Would require replacing the transport layer.
5. **Middleware composition** — Currently linear. A tree-based middleware graph could enable more complex patterns.
6. **Metrics per-route** — Current Prometheus metrics are global. Per-route histograms would require router integration.

### Long-term
7. **Replace FFI with pure Julia** — Would remove the Mongoose_jll dependency but lose battle-tested C implementation.
8. **Clustering** — Multi-process support for scaling beyond single-process limits.

---

## Next Steps

1. Add tests for new features (property forwarding, ergonomic Response constructor)
2. Consider structured response headers (biggest remaining simplification opportunity)
3. Benchmark property forwarding overhead (should be negligible due to inlining)
