# Mongoose.jl — Worklog for the modular/hardening series

> Living document: every task is planned → implemented → tested (main suite +
> acceptance + Aqua/JET) → committed as ONE focused commit, in this order.
> Update this file's status + commit hash when a task ships.

## Workflow & gates

1. Confirm scope in WORKLOG.
2. Implement in `src/`, update tests.
3. Gates before commit:
   - `julia --project=test test/runtests_stream.jl` (811 tests)
   - `julia --project=test test/acceptance/production.jl` (73 checks)
   - `julia --project=test test/quality/quality.jl` (Aqua + JET)
   - `julia --project=docs docs/make.jl` when public API changes
4. One commit per task; update WORKLOG; iterate.

## Decisions (user-confirmed)

- Auto-serialize handler returns: **always-on**; `nothing` → `204 No Content`.
- Router result ADT: **breaking** — `dispatch_route` is replaced by `match_route`
  returning an exhaustive `RouteResult` (`Matched`/`NotFound`/`MethodNotAllowed`).
- No new dependencies (audit conclusion: current `Base64 + CodecZlib + JSON +
  Mongoose_jll + PrecompileTools` is already lean).
- Examples/ stays gitignored/local (acceptance suite remains the CI-gate plan).
- 0.5 window: breaking changes are fine, no deprecation aliases.

## Task list

### Phase 1 — Ergonomics (in progress)

- [x] **T0** Create this worklog.
      commit: (current)
- [x] **T1** Unify `Headers` type for `Response` (drop raw `Vector{Pair}` splices;
      add `push!`/`append!`/helpers). *commit: `ffaf1e1`*
- [x] **T2** Auto-serialize non-`Response` handler returns (`format_response`
      dispatch: Response/StreamResponse passthrough, String→text, bytes→binary,
      Dict/NamedTuple→JSON, nothing→204). *commit: `94c3b27`*
- [x] **T3** `RouteResult` ADT: `Matched`/`NotFound`/`MethodNotAllowed{allowed}`;
      `match_route` replaces `dispatch_route`; 405 `Allow` from a method bitmask
      at match time; auto-HEAD resolved at match; protocol collapsed.
      *commit: `165fffc`*

### Phase 2 — Request layer & errors

- [ ] **T4** `LazyRequest` — lazily parse query/body/headers on first access
      (memoized), cutting eager per-request allocations. *(trade-off reviewed
      Sep 09 with the user and DEFERRED: the C buffer is transient so laziness
      can only defer parse steps, not copies; union-typed fields clash with the
      type-stability doctrine; the body copy is unavoidable anyway.)*
- [x] **T5** Typed `HTTPError` hierarchy — parametric `HTTPError{status}`
      (compile-time status, `error_status(e)` free) + named 4xx/5xx aliases
      (`NotFoundError`, `ConflictError`, `ImATeapotError`, …) + `showerror`;
      automatic mapping at the FFI boundary in `invoke_guarded` (custom
      `onerror!` handlers and `onerror!(app, status)` pages take precedence);
      unhandled `ValidationError` now defaults to **422** (was 500).
      *commit: `e9d0977`*
- [x] **T6** `RequestContext` seam — `invoke_request(ctx, req)` collapses the
      5-arg signature; the context bundles router + middleware stack + error
      pages + DI services + typed exception handlers. Typed-exception dispatch
      (`onerror!`), the built-in `HTTPError`/`ValidationError` mapping, and the
      request-`_services` injection all moved INTO the core seam, so the C
      transport and `TestClient` share one exact code path (`invoke_guarded`
      deleted). `App` holds `context::RequestContext` mirroring its live
      containers; `service!` rebuilds it (services are snapshot-copied).
      *commit: `5d72d9e`*
- [x] **T7** Middleware simplification — middleware is just a callable
      `(req, next) → response`; the dual `before`/`after` hook protocol and the
      default `(mw::AbstractMiddleware)(req, next)` are DELETED (only
      `SecurityHeaders` used `after` — converted to a call operator; no `before`
      overrides existed). `as_middleware` is the single admission point
      (docstring added). *commit: `50d1c93`*
- [x] **T8** Baked-tuple global middleware — `RequestContext.middlewares` is now
      a **tuple snapshot** of the global stack (built at App construct and
      refreshed by `use!`/`service!`, immutable in the seam), and the generic
      path walks global + route-scoped middleware with **one cursor over their
      virtual concatenation** — the per-request `[global; scoped]` array is
      gone. *commit: `716e9d4`*

### Phase 3 — Modularity & coupling

- [x] **T6** ~~`RequestContext` seam~~ — done (`5d72d9e`), see changelog.
- [x] **T7** ~~Middleware simplification~~ — done (`50d1c93`), see changelog.
- [x] **T8** ~~Composed-tuple global middleware~~ — done (`716e9d4`), see changelog.
- [ ] ~~**T9** Transport contract rewiring~~ — **DEFERRED (Sep 09)**: route the C
      event loop through `init!/listen!/poll!/send!` behind `AbstractTransport`.
      Reviewed with the user: single implementation (only the Mongoose C
      transport exists, no second transport planned), highest-risk refactor of
      the FFI event loop for zero user-visible value, and the
      `App.runtime`/`config` split + `supports_*`/`FakeTransport` traits already
      deliver the replaceability seam. Revisit only if a second transport or a
      2.0 cleanup becomes real work.
- [ ] **T10** Plugin lifecycle — `install!/configure!/start_plugin!/stop_plugin!`
      with reverse-stop rollback in `start!`.

### Phase 4 — Prod gaps & test hardening

- [x] **T11** `Request` remote address + per-IP ratelimit default — `Request`
      gained `remote_addr::Union{Nothing,String}` (peer host read from the C
      connection via the `MgAddr` struct at `mg_connection.rem`, port stripped);
      the default ratelimit key is now the remote address (per-client host)
      instead of a shared "unknown" bucket; `X-Forwarded-For`/`X-Real-IP` still
      need `trust_proxies=true`. *commit: `53e2ef9`*
- [x] **T12** `FakeExecutor` + stateful `FakeTransport` — `FakeExecutor`
      (queue + `run!`, deterministic submission-order execution), and a
      stateful `FakeTransport` that owns a stream registry: one
      `FakeStream` per streamed response (writes after delivery raise
      `StreamClosedError`), `close!` cascades over owned streams and rejects
      new requests, producer failures recorded on the stream. Old
      `StreamWriterBuffer` removed. commit: `e99919f`
- [x] **T13** Deterministic test-sync policy — wait on *conditions*, never on
      fixed wall-clock durations to assert mid-flight state. Shared `wait_until`
      helper (condition polling; `wait_for_server` rebuilt on it; TLS probe
      loops deduped), and producer→test `Channel` handshakes replace the
      timing sleeps: SSE mid-stream (`sleep(0.45)`), WS `on_open`
      (`sleep(0.1)`), WS `on_close` (`sleep(0.2)`). `timedwait` is only a
      hang-guard, never the sync. Sleeps that test the SUT's own timing
      (ratelimit window expiry, per-request timeout) stay. commit: `55c6db5`

### Phase 5 — Optional / post-release

`Expect: 100-continue` explicit reply · app-level ETag/conditional requests ·
OpenAPI-from-metadata · sessions/CSRF · HTTP/2 decision · docs build · 1.0.

## Changelog

- **Sep 08 — Phase 1 kickoff.** Decisions recorded above.
- **T1 shipped** (`ffaf1e1`): unified Headers; 763 tests + 71 acceptance +
  Aqua/JET green.
- **T2 shipped** (`94c3b27`): auto-serialize; 780 tests + 71 acceptance +
  Aqua/JET green.
- **T3 shipped** (`165fffc`): RouteResult ADT / match_route; 787 tests + 71
  acceptance + Aqua/JET + docs green. Phase 1 complete.
- **Sep 09 — T4 deferred.** Reviewed `LazyRequest` with the user: the C message
  buffer is transient, so laziness can only defer parse/transform steps (not
  copies); memoized `Union` fields violate the type-stability doctrine; body
  copy is bounded anyway. Skipped in favor of T5.
- **T5 shipped** (`e9d0977`): HTTPError hierarchy + ValidationError→422.
  811 tests + 73 acceptance + Aqua/JET + docs green. `invoke_guarded` lost its
  `isempty(exception_handlers)` fast-path (must always catch for the built-in
  mapping). Note: `ValidationError <: HTTPError{422}` was IMPOSSIBLE (Julia
  forbids subtyping concrete types) → explicit 422 branch in `invoke_guarded`
  instead. Docs: `HTTPError`/`error_status` added to api.md Errors section.
- **T6 shipped** (`5d72d9e`): RequestContext seam. 811 tests + 73 acceptance
  + Aqua/JET + docs green. `invoke_request(ctx, req)` is the single pipeline
  seam; typed-exception dispatch + HTTPError/ValidationError mapping moved from
  the transport into core. `invoke_guarded` DELETED (its logic is now inside
  `invoke_request`). App gained a `context::RequestContext` field mirroring its
  live containers (mutable Dict/Vector refs are shared, so `use!`/`onerror!`
  need no context refresh — only `service!` rebuilds it, since services are a
  snapshot NamedTuple). Trade-off accepted: `App.context` is abstract-typed →
  one virtual call per request on the seam (frozen hot path pays ~1 indirect
  call); kept `App` parametric in `R` only for API stability.
- **T7 shipped** (`50d1c93`): middleware = plain callable; `before`/`after`
  protocol deleted. 811 tests + 73 acceptance + Aqua/JET + docs green. Only one
  `after` user existed (`SecurityHeaders` → call operator); no `before`
  overrides anywhere. `before`/`after` dropped from MongooseCore exports;
  `as_middleware` docstring added (and to api.md).
- **T8 shipped** (`716e9d4`): baked-tuple global middleware. 811 tests + 73
  acceptance + Aqua/JET + docs green. `RequestContext.middlewares` is a Tuple
  (baked at construct; `use!`/`service!` re-snapshot). `execute_pipeline` gained
  a 4-arg form walking globals+scoped with one cursor over the virtual
  concatenation → the per-request `[global; scoped]` allocation is removed.
  Kept `App.middlewares::Vector` as the build-phase registration buffer. Scope
  note: true per-element static dispatch (DESIGN G3 "generated/specialized")
  would need @generated/structural recursion; the cursor keeps 1 closure
  per request — deferred as not worth the codegen complexity for ≤6-element
  stacks.
- **Sep 09 — T9 deferred.** Single-implementation (Mongoose C only) transport
  abstraction is speculative generality with the highest refactor risk and zero
  user value; the runtime/config split + `supports_*`/`FakeTransport` traits
  already provide the replaceability seam. Rationale recorded in the task list.
- **T11 shipped** (`53e2ef9`): remote_addr + per-IP ratelimit. 820 tests +
  73 acceptance + Aqua/JET + docs green. Key detail: this Mongoose_jll (7.21)
  does NOT export `mg_conn_string` → read `mg_connection.rem` (offset 40) as an
  `MgAddr` struct directly (verified against mongoose 7.21 headers; live
  loopback probe returns "127.0.0.1"). `TestClient` gained a `remote_addr`
  kwarg (default "127.0.0.1").
- **T12 shipped** (`e99919f`): FakeExecutor + stateful FakeTransport. 848
  tests + 73 acceptance + Aqua/JET + docs green. `FakeStream` deliberately has
  NO back-reference to its transport (circular struct definition in Julia —
  the registry IS the ownership; `close!` flips each stream's flags directly).
  `FakeStreamWriter` replaces `StreamWriterBuffer`. New exports: `FakeExecutor`,
  `run!`, `close!` (all added to api.md).
- **T13 shipped** (`55c6db5`): deterministic test-sync. 849 tests + 73
  acceptance + Aqua/JET + docs green. Note: `tryput!` does NOT exist in Julia
  1.12 Base → tiny `signal(::Channel)` helper (non-blocking one-shot put).
  Deliberately deferred: per-file watchdog in `runtests_stream.jl` (killing a
  hung testset task can't be done cleanly — abandoned servers leak into
  subsequent files; the flush-based runner already pinpoints hangs).