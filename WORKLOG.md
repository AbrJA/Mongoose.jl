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
      (docstring added). *commit: (T7)*

### Phase 3 — Modularity & coupling

- [ ] **T6** `RequestContext` seam — collapse `invoke_request(router, middlewares,
      errors, services, req)` into one context object.
- [ ] **T7** Middleware simplification — plain callables + one `as_middleware`;
      retire the dual `before`/`after` hook protocol.
- [ ] **T8** Composed-tuple global middleware — bake the app-global stack once.
- [ ] **T9** Transport contract rewiring — route the C event loop through
      `init!/listen!/poll!/send!` behind `AbstractTransport` (highest risk).
- [ ] **T10** Plugin lifecycle — `install!/configure!/start_plugin!/stop_plugin!`
      with reverse-stop rollback in `start!`.

### Phase 4 — Prod gaps & test hardening

- [ ] **T11** `Request` remote address (from C conn) + per-IP ratelimit default
      key.
- [ ] **T12** `FakeExecutor` + stateful `FakeTransport` (owner checks,
      one-response-per-stream, close cascade).
- [ ] **T13** Deterministic test-sync policy for the acceptance suite (no
      `sleep`/`timedwait`; `Channel`/`Event`/`errormonitor`).

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
- **T7 shipped** (this commit): middleware = plain callable; `before`/`after`
  protocol deleted. 811 tests + 73 acceptance + Aqua/JET + docs green. Only one
  `after` user existed (`SecurityHeaders` → call operator); no `before`
  overrides anywhere. `before`/`after` dropped from MongooseCore exports;
  `as_middleware` docstring added (and to api.md).