# Mongoose.jl — Worklog for the modular/hardening series

> Living document: every task is planned → implemented → tested (main suite +
> acceptance + Aqua/JET) → committed as ONE focused commit, in this order.
> Update this file's status + commit hash when a task ships.

## Workflow & gates

1. Confirm scope in WORKLOG.
2. Implement in `src/`, update tests.
3. Gates before commit:
   - `julia --project=test test/runtests_stream.jl` (751 tests)
   - `julia --project=test test/acceptance/production.jl` (71 checks)
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
- [ ] **T1** Unify `Headers` type for `Response` (drop raw `Vector{Pair}` splices;
      add `push!`/`append!`/helpers). *commit: —*
- [ ] **T2** Auto-serialize non-`Response` handler returns (`format_response`
      dispatch: Response/StreamResponse passthrough, String→text, bytes→binary,
      Dict/NamedTuple→JSON, nothing→204). *commit: —*
- [ ] **T3** `RouteResult` ADT: `Matched`/`NotFound`/`MethodNotAllowed{allowed}`;
      `match_route` replaces `dispatch_route`; 405 `Allow` from a method bitmask
      at match time; auto-HEAD resolved at match; protocol collapsed.
      *commit: —*

### Phase 2 — Request layer & errors

- [ ] **T4** `LazyRequest` — lazily parse query/body/headers on first access
      (memoized), cutting eager per-request allocations. *(trade-off pending
      user confirm)*
- [ ] **T5** Typed `HTTPError` hierarchy (`ParseError`/`ProtocolError`/
      `TimeoutError`…), `Base.showerror` on each, transport error wrapping at
      the FFI boundary.

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

- **Sep 08 — Phase 1 kickoff.** Decisions recorded above. T1 begins.