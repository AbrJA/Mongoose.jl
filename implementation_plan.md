# Mongoose.jl Architecture Refactor

Full refactor to make Mongoose.jl modular, protocol-agnostic, and production-ready. Breaking changes are acceptable per user direction.

## Proposed Changes

### FFI Layer — `src/ffi/`

Extract all C interop into a clean, isolated layer.

#### [NEW] [constants.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/ffi/constants.jl)
- All Mongoose event constants (`MG_EV_*`) including WebSocket events for future use
- `MG_MAX_HTTP_HEADERS`, `MG_MGR_SIZE` (fixed from magic `128`)

#### [NEW] [structs.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/ffi/structs.jl)
- `MgStr`, `MgHttpHeader`, `MgHttpMessage` — C struct mappings
- `to_string` helper
- Type alias `MgConnection = Ptr{Cvoid}`

#### [NEW] [bindings.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/ffi/bindings.jl)
- All `ccall` wrappers: `mg_mgr_init!`, `mg_mgr_free!`, `mg_mgr_poll`, `mg_http_listen`, `mg_http_reply`, `mg_conn_get_fn_data`, `mg_log_set_level`
- Simplified signatures (remove unnecessary `Base.unsafe_convert` calls)

---

### Core Layer — `src/core/`

Define the abstract type system, shared server infrastructure, errors, and middleware.

#### [NEW] [types.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/core/types.jl)
- `abstract type AbstractMessage end`
- `abstract type AbstractRequest <: AbstractMessage end`
- `abstract type AbstractResponse <: AbstractMessage end`
- `abstract type Server end`
- `abstract type Route end`
- `Middleware` type alias and pipeline execution

#### [NEW] [errors.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/core/errors.jl)
- `MongooseError <: Exception`
- `RouteError`, `ServerError`, `BindError`

#### [NEW] [server.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/core/server.jl)
- `Manager` struct with fixed size constant (not magic `128`)
- `ServerCore` — shared fields via composition (`manager`, `handler`, `timeout`, `master`, `router`, `running` as `Threads.Atomic{Bool}`, `middleware`)
- `cleanup!`, `setup_listener!`, `start_master!`, `run_blocking!`, `stop_master!`, `free_resources!`
- `use!` function for adding middleware

#### [NEW] [registry.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/core/registry.jl)
- Thread-safe registry with `ReentrantLock`
- `register!`, `unregister!`, `shutdown!()` (all-servers)

#### [NEW] [events.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/core/events.jl)
- Single unified `@cfunction` callback
- `select_server` helper
- `dispatch_event!` using `if/elseif` chain dispatching to `handle_event!` methods
- Default `handle_event!` fallbacks for `Server` type

#### [NEW] [middleware.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/core/middleware.jl)
- `Middleware` type alias `Function`
- `execute_middleware` pipeline runner
- Middleware receives `(request, params, next)` where `next` is the continuation

---

### HTTP Layer — `src/http/`

All HTTP-specific logic isolated from core.

#### [NEW] [types.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/http/types.jl)
- `HttpRequest <: AbstractRequest` (renamed from `Request`)
- `HttpResponse <: AbstractResponse` (renamed from `Response`)
- `IdRequest`, `IdResponse` (connection-tagged messages)
- `build_request` from C message
- `_method_to_symbol` with improved validation
- `_headers` parser
- `to_headers` (renamed from `serialize`)
- `HttpResponse` convenience constructors

#### [NEW] [router.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/http/router.jl)
- `Node`, `Fixed`, `Router`, `Matched` structs
- `match_route` using `eachsplit` (zero-alloc)
- `_match` recursive trie walk
- `execute_handler` decoupled from response creation
- Constant `EMPTY_PARAMS`

#### [NEW] [handler.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/http/handler.jl)
- `handle_event!` methods for `MG_EV_HTTP_MSG` on both server types
- `handle_event!` for `MG_EV_CLOSE` on `AsyncServer`

#### [NEW] [utils.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/http/utils.jl)
- `decode_range`, `parse_params`
- `from_query` (renamed from `deserialize`)

---

### Server Implementations — `src/servers/`

#### [NEW] [sync.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/servers/sync.jl)
- `SyncServer <: Server` using `ServerCore` composition
- `setup_resources!`, `start_workers!`, `stop_workers!`, `handle_request`
- `run_event_loop` for sync mode

#### [NEW] [async.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/servers/async.jl)
- `AsyncServer <: Server` using `ServerCore` composition
- Worker channels, connections dict
- `setup_resources!`, `start_workers!`, `stop_workers!`, `handle_request`, `process_responses!`
- `run_event_loop` for async mode with `Threads.@spawn` for master

---

### Main Module

#### [MODIFY] [Mongoose.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/Mongoose.jl)
- Clean entry point: only `using`, `include()`, `export`, constants, `route!`, `start!`, `shutdown!`
- Public API preserved: `AsyncServer`, `SyncServer`, `HttpRequest` (alias `Request`), `HttpResponse` (alias `Response`), `start!`, `shutdown!`, `route!`, `from_query`, `to_headers`, `use!`

---

### Deleted Files

#### [DELETE] [structs.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/structs.jl)
#### [DELETE] [routes.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/routes.jl)
#### [DELETE] [events.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/events.jl)
#### [DELETE] [servers.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/servers.jl)
#### [DELETE] [registry.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/registry.jl)
#### [DELETE] [utils.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/utils.jl)
#### [DELETE] [wrappers.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/wrappers.jl)

---

### Tests

#### [MODIFY] [runtests.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/test/runtests.jl)
- Update to use new type names (`HttpRequest`/`HttpResponse` or aliases `Request`/`Response`)
- Add middleware test
- All existing test semantics preserved

## Verification Plan

### Automated Tests

Run the existing test suite which covers sync server, async server, dynamic routing, error handling, multithreading, and multiple instances:

```bash
cd /home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl && julia --project -t 4 -e 'using Pkg; Pkg.test()'
```

All 4 existing test sets must pass: `SyncServer`, `AsyncServer`, `Multithreading`, `Multiple Instances`.
