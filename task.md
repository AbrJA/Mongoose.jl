# Mongoose.jl Full Architecture Refactor

## Phase 1: FFI & Core Foundation
- [ ] Create `src/ffi/constants.jl` — event constants, sizes
- [ ] Create `src/ffi/structs.jl` — C struct mappings (MgStr, MgHttpMessage)
- [ ] Create `src/ffi/bindings.jl` — all ccall wrappers
- [ ] Create `src/core/types.jl` — abstract types & interfaces
- [ ] Create `src/core/errors.jl` — custom exception types

## Phase 2: Server & Middleware
- [ ] Create `src/core/server.jl` — ServerCore, Manager, lifecycle
- [ ] Create `src/core/registry.jl` — thread-safe registry
- [ ] Create `src/core/middleware.jl` — middleware pipeline

## Phase 3: HTTP Layer
- [ ] Create `src/http/types.jl` — HttpRequest, HttpResponse
- [ ] Create `src/http/router.jl` — trie router (from routes.jl)
- [ ] Create `src/http/handler.jl` — HTTP event handling
- [ ] Create `src/http/utils.jl` — URL decode, query parse

## Phase 4: Server Implementations & Events
- [ ] Create `src/servers/sync.jl` — SyncServer
- [ ] Create `src/servers/async.jl` — AsyncServer
- [ ] Create `src/core/events.jl` — unified event dispatch

## Phase 5: Main Module & Integration
- [ ] Rewrite [src/Mongoose.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/Mongoose.jl) — clean module entry point
- [ ] Delete old files (structs.jl, routes.jl, events.jl, servers.jl, registry.jl, wrappers.jl, utils.jl)

## Phase 6: Tests & Verification
- [ ] Update [test/runtests.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/test/runtests.jl) to work with new API
- [ ] Run tests and verify all pass
