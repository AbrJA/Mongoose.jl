# Mongoose.jl — Design Redesign (TARGET ARCHITECTURE)

Status: **implemented in large part** across the `feat/modular` series.
Companion to `ARCHITECTURE_REPORT.md` (the audit) and this repo's current
code. Items not yet done remain marked *target*.

## Implemented (as of the modularization series)

- G1 core without FFI: `MongooseCore` loads standalone
  (`using Mongoose.MongooseCore`); `invoke_request`/`FakeTransport` run full
  requests with no server and no `Mongoose_jll`.
- G2/g router replaceability: `AbstractRouter` protocol with contract-by-
  fallback methods; `App{R<:AbstractRouter}`; `Router` = exact Dict +
  ordered typed-tuple patterns. `freeze!(router)` closes the route table
  (AOT/`--trim=safe` contract).
- G3 typed dispatch: `Endpoint` (handler + scoped middleware + metadata);
  `RouteMatch{P}` with typed param tuples; middleware accepts plain
  callables (`FunctionMiddleware`); the onion chain runs via a single
  closure + cursor (no per-layer closure allocation).
- **Compiled frozen-route dispatch** (the real `--trim=safe` profile):
  `freeze!` now *compiles* the closed table into a `CompiledDispatch`
  (`core/compiled.jl`). Each fixed route and parametric route gets pre-baked
  terminals (handler + scoped middleware fused; the handler's concrete type
  is captured at bake time), parametric matching runs through a statically-
  typed heterogeneous ops chain with index-walking (no `Vector{String}`
  split), and the pipeline resolves requests via the optional
  `terminal_for(router, req)` capability with no per-request closure or
  `[global; scoped]` concat. Semantics (fixed-first, registration order,
  `"*"` fallback, 405, auto-HEAD, scoped ordering, error remap) are tested
  for exact parity against the generic path.
- G4 execution: `AbstractExecutor` + `SyncExecutor`/`AsyncExecutor`; App
  always holds an executor; timeouts applied at job build time.
- Transport seam: `AbstractTransport` + capability traits
  (`supports_websocket/tls/streaming`); `TestClient` is `FakeTransport`.
- Derived type-stability fixes: `App.services` is a typed
  `ServiceRegistry{T<:NamedTuple}` (`service(req, Val(:x))` is stable);
  `parse_method` simplified; streaming producers run off the poll thread
  (channel-backed `StreamWriter`); WS origin allowlist; typed exception
  handlers; binary responses keep-alive; executor marker instead of
  `Union{Nothing,…}`.
- Test suite split into topic modules (`test/{unit,routing,middleware,
  server,http,websocket,tls,quality}`) and a production example with an
  interactive dashboard (`examples/production/`, gitignored).

## Remaining *target* items

- Composed-tuple middleware (immutable App + builder): the *pipeline* side of
  codegen. The compiled path already fuses each route's scoped stack once at
  freeze time; app-global middleware is still concatenated/wrapped per
  request via `execute_pipeline`.
- Full written transport contract (`init!/listen!/poll!/send!`) behind the
  C adapter — `AbstractTransport` + traits exist; the C event loop is not
  yet rewired through them.
- Registry GC-rooting redesign — deliberately shelved (current per-event
  SpinLock lookup is uncontended and GC-safe).

---

## 0. Why we are rethinking this

The current codebase passes 492 tests and Aqua/JET, but it is hard to evolve:

1. **One flat `module Mongoose`** with a strictly ordered chain of 25 `include`s. No
   encapsulation: the router knows nothing of transport, yet nothing can be loaded or
   tested without the FFI layer.
2. **`App` is a god object** (22 fields): config + runtime + FFI manager + WS tracking +
   DI + hooks + async worker pool all in one mutable struct.
3. **Transport is entangled with application logic** — `http_handler.jl` does WS upgrade,
   body limits, static mounts, routing, middleware, DI, error pages, request IDs, and the
   worker queue.
4. **Handlers are untyped dynamic closures.** `MethodMap.handlers::Union{Nothing,Function}`
   + `RouteMatch.params::Vector{Any}` + `handler(req, matched.params...)` means every
   request is a dynamic dispatch with splatted, boxed params that Julia can never
   specialize.
5. **Middleware is a per-request recursion** (`_build_chain`, closure-per-middleware), and
   group middleware is flattened into per-route closures at mount time.
6. **A pile of dead/broken code** accumulated (now mostly removed — see §6).

Design goals for the target (in priority order):

- **G1** Core (Request/Response/Router/Middleware) must be loadable and testable with **no
  server and no FFI**.
- **G2** Transport (Mongoose C adapter) must be **swappable** behind a narrow interface.
- **G3** Route handling and middleware must be **specializable** (type-stable dispatch), not
  `Any` splats and recursive closures.
- **G4** Server state must split **immutable Config vs mutable Runtime**, and each subsystem
  (WS, worker pool, DI, lifecycle) must own its state.
- **G5** One connection identity scheme (never raw pointers as dict keys).

---

## 1. Module layout (real internal submodules)

Replace the flat include chain with nested modules. The public API stays `using Mongoose`.

```
src/
└── Mongoose.jl            # facade: re-export + public API surface, thin
    └── core/
        └── MongooseCore   # DONE deps: stdlib + JSON + CodecZlib only
            ├── Request / Response / Headers / Formats / Status / Cookie
            ├── Router          # trie + MethodMap + RouteGroup  (G1, G3)
            ├── Middleware      # AbstractMiddleware, PathFilter, compose (G3)
            ├── Pipeline        # process(app_or_handler, req) → Response
            └── DI              # typed Services{NamedTuple}
        └── server/
            └── MongooseServer  # depends on MongooseCore
            ├── Config          # immutable ServerConfig (already exists, promoted)
            ├── Runtime         # per-instance mutable state
            ├── Lifecycle       # start!/shutdown!/drain/registry/TLS-normalize
            └── Workers         # sync + async worker pool
        └── transports/
            └── MongooseTransport   # depends on MongooseCore + MongooseServer
            ├── FFI bindings, events, adapter, connection, ws_handler
```

Key testability win: `using MongooseCore` gives you `Request`, `Response`, `Router`,
`Pipeline`, `TestClient`. **`Pipeline` is the seam** — both the C transport (via
`invoke_http`) and `TestClient` (today) call it; it belongs in Core.

---

## 2. Typed routing (G3) — the central change

### Today
```julia
# MethodMap holds Union{Nothing,Function}; RouteMatch.params::Vector{Any}
handler(req, matched.params...)           # dynamic split, boxed Any
```

### Target
```julia
# Per (method,path) we store a concrete callable; the router never splats Any.
register_match!(node, method, CompiledRoute(f_handler, arity))
```

Dispatch:
- Build the call site at **registration time**, not request time: `f(req)` for arity-1
  handlers, `f(req, p1,...,pn)` for typed params. Represent the handler as a **functor
  with a concrete method** or a pre-specialized closure, so the call is
  statically-resolvable.
- Param parsing stays trie-based (`:id::Int`), but the parsed values are transformed into a
  **`Tuple`/`NamedTuple`** (`params::NTuple{N,Any}` still forces boxing) — instead,
  specialize per segment type so `RouteMatch{Int,String}` can hold a tuple.
- `MethodMap` keeps its 7 slot-fields but becomes
  `get::Union{Nothing, CompiledRoute{...}}`, etc.

### RouteGroup
Move scope logic into the router, not closures: give `TrieNode`/`RouteGroup` an attached
middleware vector **resolved at dispatch** (prefix-scoped), and let the pipeline compose
`app.middlewares ++ scoped_middlewares` in one pass. This makes group middleware
introspectable and avoids one closure per route.

---

## 3. Composed middleware (G3)

### Today
`_build_chain(middlewares, req, handler, idx)` — one closure per middleware per request,
recursive dynamic dispatch over `AbstractMiddleware`.

### Target
Compile the stack **once at `use!` time** into a single closed-over function per
(length, element-types) signature:

```julia
compose(mws::Vector{AbstractMiddleware}, final) -> (req) -> Response
```

- Group middlewares by their concrete trailing types at registration so the composed
  function is specialized (this is how Julia "loses" dynamism: abstract container, concrete
  composed call).
- Keep `before`/`after`/callable protocol as the extension surface for users (that is the
  public contract), but the *pipeline execution* becomes generated/specialized.

---

## 4. App decomposition (G4)

Replace the single `App` with:

```julia
struct ServerConfig          # ↔ today's ServerConfig, promoted to public, immutable (DONE shape)
    poll_timeout::Int
    max_body::Int
    ...
    services::NTuple/...     # typed: see §5
end

mutable struct Runtime       # owned by Server, mutated only inside lifecycle/workers
    running::Threads.Atomic{Bool}
    manager::Manager
    c_handler::Ptr{Cvoid}
    tls::Union{Nothing,TLSConfig}
    ws_clients::Dict{Int,WsSession}
    id_seq / conn_seq
    worker_tasks, calls, replies, connections, inflight
end

struct Server                # the new public handle; owns Config + Runtime
    config::ServerConfig
    runtime::Runtime
    router::Router
    middlewares::Vector{AbstractMiddleware}
    mounts::Vector{Tuple{String,String}}
    errors / hooks
end
```

- Constructor does the validation `ServerConfig(...)` does today; `start!` allocates
  `Runtime`. Many of today's `App` fields become constructor-only (no mutation after
  start), shortening the list of *mutated* state to the Runtime block.
- The `getproperty`/`Val` forwarding hack (`_app_getproperty`) goes away; field access is
  plain.
- Retain `App` as a deprecated alias only if a compatibility window is needed.

Transport boundary (G2): `Server` exposes a narrow contract consumed by the transport:
`process_http!(server, req)`, `register_ws/sessions`, `send(...)` primitives. The C adapter
implements event → these calls; it never pokes `Runtime.connections` directly.

---

## 5. Typed dependency injection (G1/G3)

### Today
`services::Dict{Symbol,Any}`, retrieved via `service(req, :db, T)` (runtime `TypeError`
assert) through a `req.context[:_app]` side-channel.

### Target
```julia
struct Services{T<:NamedTuple}
    deps::T
end

App(; services=(db=pool, cache=redis))   # named tuple
```

- Inject at **dispatch/invoke time** into the request so handlers can do
  `svc = service(req, Val(:db))` — type-stable, no `Any`.
- Keep `service!(app, :name, val)` only as a deprecated convenience that converts to the
  NamedTuple.
- Remove the `context[:_app]` back-reference; the pipeline already receives the owning
  server.

---

## 6. Known debt inventory (fix alongside)

**Cleanup — done this pass (verify still intended):**
- Deleted orphan `src/router/static.jl` (468 lines, never included).
- Deleted `fail!` (referenced non-existent `server.core.errors`), `mount_static!`,
  `resolve_request_id_fast`, `ws_forget!`, empty `AbstractWsEndpoint`, `context.jl` stub.
- Split request-id and async connection-id onto separate counters (`id_seq`/`conn_seq`).

**Still broken / to fix in target:**
| Item | Location | Fix |
|---|---|---|
| WS connection keying by raw `Int(conn)` | `ws_handler.jl` | counter-keyed sessions uniformly |
| WS idle sweep can't resolve conn in async | `ws_handler.jl:137` | session carries conn id |
| Streaming/`send_stream_response!` runs on poll thread in async, blocking the loop | `async.jl` / `connection.jl` | producer on worker; event loop only flushes |
| `invoke_timed_http` leaks the spawned task on timeout | `async.jl:141` | cooperative timeout or task cancellation protocol |
| Per-request allocations (URI/headers/body/query copies) | `adapter.jl` | deferred/parsed views, pooled buffers — only if hot-path benchmark demands |
| `EMPTY_PARAMS = Any[]` shared mutable global | `trie.jl:97` | per-call immutable empty tuple |
| `RouteMatch.params::Vector{Any}` | `trie.jl:92` | typed tuple per §2 |
| Registry SpinLock hit per event | `registry.jl` | per-server fn_data resolving to a GC-rooted server reference |
| `on_http_message` mixed WS/HTTP/static logic | `http_handler.jl` | move decision into Core pipeline; transport only adapts events |
| `route_count` traverses trie per `show()` | `core.jl` | cached count |
| `status_reason` / `format_headers` re-serialization per response | `connection.jl` | reuse/benchmark before optimizing |

**Conventions to lock in:**
- No global mutable state (only `const` + atomics inside Runtime).
- Dict keys never pointers.
- Public API exported from `Mongoose` facade only; internals via `using MongooseCore` etc.
- Every layer must have unit tests that never bind a port (split `test/unit/` vs
  `test/integration/` per the report §6).

---

## 7. Migration plan

1. **Extract `MongooseCore`** (no behavior change): move Request/Response/.../Router/
   Middleware/Pipeline/TestClient into nested module; keep `Mongoose` re-exporting.
   → tests unchanged, proves feasibility.
2. **Typed routes** (G3): replace `Vector{Any}` splat dispatch with compiled route calls;
   add benchmark to prove no regression.
3. **Composed middleware**: specialize pipeline; make group/route middleware introspectable.
4. **App → Server + Config/Runtime + typed services**; drop `getproperty` hack and
   `context[:_app]`.
5. **Transport decoupling**: `transport/mongoose` becomes `MongooseTransport` implementing
   the narrow interface; fix WS keying/streaming/timeout items from §6.
6. **Housekeeping**: remove leftover aliases, split tests, docs update.

Each step is independently testable and shippable; that is the point of doing it in this
order.

---

## 8. Decisions still open

- Keep `App` as a stale alias during v1→v2, or break loudly? (#: proposal: break loudly,
  bump major).
- Suppport a second (Rust `khttp/`) transport now, or only keep the interface clean?
  (#: proposal: interface only; `khttp/` is an experimental Rust subtree and unmaintained.)
- Streaming: Ok to restrict `StreamResponse` to async workers so the event loop never runs
  user code? (This matches today's docstring claim but not the code — worth deciding.)