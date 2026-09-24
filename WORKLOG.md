# Mongoose.jl — Worklog for the modular/hardening series

> Living document: every task is planned → implemented → tested (main suite +
> acceptance + Aqua/JET) → committed as ONE focused commit, in this order.
> Update this file's status + commit hash when a task ships.

## Workflow & gates

1. Confirm scope in WORKLOG.
2. Implement in `src/`, update tests.
3. Gates before commit:
   - `julia --project=test test/runtests.jl` (1058 tests; this is the
     `Pkg.test`/CI entrypoint — the sanctioned gate)
   - `julia --project=test test/acceptance/production.jl` (80 checks)
   - `julia --project=test test/quality/quality.jl` (Aqua + JET)
   - `julia --project=docs docs/make.jl` when public API changes
   - `test/runtests_stream.jl` is a *diagnostic* runner (same files, per-file
     live output, fail-fast); run it only to localize a hang/failure — not as
     a second gate.
4. One commit per task; update WORKLOG; iterate.

## Decisions (user-confirmed)

- Auto-serialize handler returns: **always-on**; `nothing` → `204 No Content`.
- Router result ADT: **breaking** — `dispatch_route` is replaced by `matchroute`
  returning an exhaustive `RouteResult` (`Matched`/`NoMatch`/`WrongMethod`).
- No new dependencies (audit conclusion: current `Base64 + CodecZlib + JSON +
  Mongoose_jll + PrecompileTools` is already lean).
- Examples/ stays gitignored/local (acceptance suite remains the CI-gate plan).
- 0.5 window: breaking changes are fine, no deprecation aliases.
- **Auto-HEAD REMOVED.** HEAD is served only by an explicit `head!` route;
  unregistered HEAD answers `405` with `Allow` naming exactly the served
  methods. Rationale (user decision, Sep 10): mongoose-C offers no
  binary-length-aware native reply (`mg_http_reply` is printf/`strlen`-based),
  so a spec-correct HEAD (`Content-Length` equal to the GET representation)
  requires hand-framing that bypasses mongoose's framing state. Rather than
  ship a trick, the feature is removed; the transport's only hand-framed
  responses (binary bodies, streams) always advertise `Connection: close`.

### Reliability hardening (Session: Sep 10 — uncommitted)

- [ ] **R1** Hand-framed responses never rely on keep-alive reuse. Verified:
      a raw `mg_send` frame wedges the socket for the next pooled request.
      Binary `Vector{UInt8}` responses (and streams, already) advertise
      `Connection: close`; string responses stay on native `mg_http_reply`.
- [ ] **R2** Auto-HEAD removed (see Decisions); route/strip machinery deleted
      from `router.jl`, `process.jl`, `compiled.jl`; explicit `head!` bodies
      are stripped by the transport (`invoke_http` → RFC 9110 §3.1).
- [ ] **R3** Blocking `start!` now runs the event loop on a task and waits on
      it (Julia-safe point), so a *delivered* `InterruptException` (Ctrl+C)
      unwinds to graceful shutdown. Caveat verified in-session: this sandbox's
      Julia segfaults on SIGINT even for a bare `sleep`, so it cannot be
      demonstrated here; docstring updated to state the dependency.
- [ ] **R4 (framework bug)** Frozen/compiled param dispatch matched a shorter
      request against a longer route: `_walk_ops`'s `LitOp` accepted a zero-
      length segment (`j0 == 0` treated as a match), so `GET /api/orders/1`
      aliased `POST /api/orders/:id::Int/payments` → 405. Fixed in
      `src/core/compiled.jl` (literal must match a real segment); regression
      test added. Found while validating the rewritten Shop API example.
- [ ] **E1** Production example rewritten to a realistic surface (local-only,
      gitignored): magic-link customer auth + sessions, real product catalog
      with reviews + moderation, stock-enforced carts, checkout with
      subtotal/shipping/tax (integer cents), card-payment step, order state
      machine with fulfilment, admin report/review/inventory consoles, partner
      SKU feed, ops maintenance switch, SSE order/stock/review events, WS
      inventory console. Demo-only endpoints (echo/formats/meta/legacy/teapot/
      chat) removed; dashboard updated; money math unit-checked
      (2×420 + 499 + 8% → 1406).
- [ ] **R5 Naming pass (breaking, 0.5 window)** — collisions + consistency:
      - Router ADT vs HTTP-error collision resolved: `NotFound` → `NoMatch`,
        `MethodNotAllowed` → `WrongMethod` (the HTTP errors keep `*Error`
        names).
      - De-underscored protocol names: `match_route` → `matchroute`,
        `match_route_exact` → `hasroute(router, path)::Bool` (ownership check,
        catch-all excluded), `route_count` → `Base.length(router)`,
        `has_ws_routes` → `haswsroutes`, `supports_websocket` → `supportsws`,
        `supports_tls` → `supportstls`, `supports_streaming` →
        `supportsstream`; `to_lower` unexported (internal only).
      - `MongooseCore` → `Kernel` (`Core` would shadow the Julia language
        core — e.g. `Core.stdout` in `util/log.jl`; `Kernel` is
        collision-free).
      - Gotcha: on Julia 1.13 an unqualified `function length(...)` in a
        module creates a FRESH binding shadowing `Base.length` — router
        extensions must be written `Base.length(r::Router)`.
- [ ] **R6 Structure + surface finalization**:
      - Files relocated by dependency: `streaming/sse.jl` → `core/streaming.jl`
        (FFI-free, Kernel-ownable), `testing.jl` → `transport/fake.jl`
        (FakeTransport is App-coupled — it is the reference TRANSPORT layer,
        not core), `protocol/base.jl` → `server/base.jl` (1-file dir
        dissolved). Root now holds only the facade.
      - Capability traits standardized on NOUNS: `supportsws`, `supportstls`,
        `supportstream` (the file had drifted: exports said `supportsstream`,
        the impl said `supportsstreaming`).
      - Zero-underscore goal reached across both exported surfaces:
        `invoke_request` → `process`, `execute_pipeline` →
        `runpipeline`, `terminal_for` → `terminalfor`, `error_response` →
        `errorresponse`, `error_status` → `errorstatus`, `status_reason` →
        `statusreason`, `parse_query` → `parsequery`, `strip_query` →
        `stripquery`, `format_headers` → `formatheaders`, `url_decode` →
        `urldecode`, `content_type_pair` → `contenttypepair`, `get_handler` →
        `gethandler`, `get_endpoint` → `getendpoint`, `set_handler!` →
        `sethandler!`, `ws_endpoint` → `wsendpoint`, `as_middleware` →
        `asmiddleware`. `to_lower` and `sanitize_header_value` unexported
        (internal, qualified `Kernel.` at call sites).
      - Facade trimmed of test-double internals: `FakeExecutor`/`run!` remain
        extension-surface in Kernel (documented in api.md), no longer
        `using Mongoose` visible.
      - Regex gotcha: `\b` after `!` never matches (`!`+`(` are both
        non-word) — plain `.replace` for `!`-terminated names.

## Task list

### Phase 1 — Ergonomics (in progress)

- [x] **T0** Create this worklog.
      commit: (current)
- [x] **T1** Unify `Headers` type for `Response` (drop raw `Vector{Pair}` splices;
      add `push!`/`append!`/helpers). *commit: `ffaf1e1`*
- [x] **T2** Auto-serialize non-`Response` handler returns (`format_response`
      dispatch: Response/StreamResponse passthrough, String→text, bytes→binary,
      Dict/NamedTuple→JSON, nothing→204). *commit: `94c3b27`*
- [x] **T3** `RouteResult` ADT: `Matched`/`NoMatch`/`WrongMethod{allowed}`;
      `matchroute` replaces `dispatch_route`; 405 `Allow` from a method bitmask
      at match time; auto-HEAD resolved at match; protocol collapsed.
      *commit: `165fffc`*

### Phase 2 — Request layer & errors

- [ ] **T4** `LazyRequest` — lazily parse query/body/headers on first access
      (memoized), cutting eager per-request allocations. *(trade-off reviewed
      Sep 09 with the user and DEFERRED: the C buffer is transient so laziness
      can only defer parse steps, not copies; union-typed fields clash with the
      type-stability doctrine; the body copy is unavoidable anyway.)*
- [x] **T5** Typed `HTTPError` hierarchy — parametric `HTTPError{status}`
      (compile-time status, `errorstatus(e)` free) + named 4xx/5xx aliases
      (`NotFoundError`, `ConflictError`, `ImATeapotError`, …) + `showerror`;
      automatic mapping at the FFI boundary in `invoke_guarded` (custom
      `onerror!` handlers and `onerror!(app, status)` pages take precedence);
      unhandled `ValidationError` now defaults to **422** (was 500).
      *commit: `e9d0977`*
- [x] **T6** `RequestContext` seam — `process(ctx, req)` collapses the
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
      overrides existed). `asmiddleware` is the single admission point
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
- [ ] ~~**T10** Plugin lifecycle~~ — **DEFERRED (Sep 09)**: `install!/configure!/
      start_plugin!/stop_plugin!` with reverse-stop rollback. Reviewed with the
      user: no consumers inside or outside the repo (use!/route!/service! and
      onstart!/onstop! already compose bundles), the rollback selling point is
      moot because `start!` treats hook failure as logged-and-continue (no
      partial-start state to roll back), and API-without-usage is debt — design
      the plugin API when the first real plugin needs it.

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

`Expect: 100-continue` explicit reply (VERIFIED: mongoose build omits the
interim 100 but accepts the request — compliant, no action) · ~~app-level
ETag/conditional requests~~ **shipped** · OpenAPI-from-metadata · sessions/CSRF
· HTTP/2 decision · docs build item done (keep building at each API change) ·
1.0.

## Audit (Sep 17) — deep review findings & batch plan

Four parallel audits (concurrency/lifecycle, HTTP+WS protocol/security,
API/design, prod-readiness) plus live verification probes. Status:
`[ ]` pending · `[~]` in progress · `[x]` shipped (commit hash).
Verification tags from the audit: **[live]** reproduced on a running server,
**[code]** verified by reading, **[rep]** reported.

### Batch 6 — P0 + P1 hotfix (start here)
- [x] **6.1 [live] P0: chunked requests hang.** `adapter.jl:49` called bare
  `decode_chunked` (Kernel-only, unexported) → `UndefVarError`, no response;
  also a double-decode (Mongoose already de-chunks `hm.body`). Fixed: drop the
  adapter branch, wire tests (chunked IO body + payload that looks chunked).
  *commit: `7997167`*
- [x] **6.2 [live] CORS intercepts every OPTIONS** and 403s when `Origin` is
  absent. Fixed: preflight only with `Origin` + `Access-Control-Request-Method`;
  `Vary: Origin` also on denied origins. *commit: `db56dce`*
- [x] **6.3 [live] `Connection: Close` echo is case-sensitive.** Fixed:
  token-aware case-insensitive check. *commit: `db56dce`*
- [x] **6.4 [live] `SameSite=None` dropped; no CRLF validation.** Fixed:
  always emitted; CTL rejected in Cookie fields/setcookie/redirect.
  *commit: `db56dce`*
- [x] **6.5 [code] WS idle timeout ms-vs-seconds, no force-close.** Fixed:
  `/1000`, sweep every 1s, `closing` marked, Close + `mg_close_conn` (new
  binding). Server-side test asserts registration drop + `on_close`.
  *commit: `db56dce`*
- [x] **6.6 [code] WS upgrade ran hooks/registration before the handshake
  check.** Fixed: header pre-check; non-upgrade GET → 426 with no side
  effects. *commit: `db56dce`*
- [x] **6.7 [live] `ws_send_all` not exported.** Fixed: facade export.
  *commit: `db56dce`*
- [x] **6.8 [code] Malformed JSON/form/multipart became 500.** Fixed: 400/415
  (+ missing boundary → 400); acceptance updated. *commit: `db56dce`*
- [x] **6.9 [code] `PathFilter` not segment-aware.** Fixed: whole-segment
  match + trailing-slash normalization. *commit: `db56dce`*
- [x] **6.10 [code] Logger missed 500s; interleaving writes.** Fixed:
  try/catch logs 500 then rethrows; single-write line. *commit: `db56dce`*

### Batch 7 — lifecycle & concurrency
- [x] 7.1 `runtime.bg_tasks` pushed from workers without a lock + unbounded
  growth until shutdown. Fixed: `bg_track!`/`bg_prune!`/`bg_snapshot` under a
  spinlock; the async loop prunes on its health tick. *commit: `c021fa7`*
- [x] 7.2 `stop!(AsyncExecutor)` can deadlock. Fixed: bounded join
  (`timeout`, defaults to 5 s, `shutdown!` passes `drain_timeout_ms`) that
  drains replies while waiting; `stopping` flag blocks respawns.
  *commit: `c021fa7`*
- [x] 7.3 `haspending` ignores `runtime.streams` → SSE truncated at shutdown.
  Fixed: streams counted; `drain_poll!` drains them; final poll flushes the
  terminal chunk; regression test shuts down mid-SSE. *commit: `c021fa7`*
- [x] 7.4 Stream producers run on the poll thread. Fixed: `Threads.@spawn`.
  *commit: `c021fa7`*
- [x] 7.5 WS replies keyed by raw connection pointer. Fixed: monotonic
  generation ids (`ws_gen_ids`), stale replies dropped; unit test.
  *commit: `c021fa7`*
- [x] 7.6 Worker exception outside the handler try loses the reply and leaks
  the `connections` entry; `supervise_workers!` races `stop!`.
  Fixed: per-job catch keeps workers alive; `_http_job` always returns a
  reply; supervisor no-ops once stopping. *commit: `c021fa7`*
- [x] 7.7 `decode_chunked` overflow guards. Fixed + hostile-size tests.
  *commit: `c021fa7`*

### Batch 8 — CI / ops / release
- [x] 8.1 CI now triggers on every push/PR and runs the acceptance + quality
  gates after `Pkg.test`; `quality.jl` fails when JET findings exceed the
  pinned baseline (36, JSON ignored) instead of printing an unfailable report.
  *commit: `809fc79`*
- [x] 8.2 SIGTERM (POSIX) handler flips an atomic flag; the event loops observe
  it and the loop task runs the graceful path (no self-deadlock); `atexit`
  shuts down registered servers. Child-process SIGTERM test in acceptance.
  *commit: `4f96f0b`*
- [x] 8.3 Sync mode: `request_timeout_ms` is ignored there — `start!` now warns
  and the App docs state it. Decision: sync stays the default (documented
  trade-off) rather than silently switching every app to a worker pool.
  *commit: `4f96f0b`*
- [x] 8.4 `header_timeout_ms` (sweep closes conns that never complete a
  request) + `max_connections` (refuse at accept) with tests.
  *commit: `4f96f0b`*
- [x] 8.5 Cap verified empirically: 8 MiB round-trips, 10 MiB resets (the
  audit's 3 MiB guess was wrong). `max_body_bytes`/`ws_max_frame_bytes` above
  the ceiling are rejected at construction. *commit: `4f96f0b`*
- [x] 8.6 Metrics gauges via the new `attach!(middleware, server)` hook:
  `/metrics` now reports `mongoose_connections`, `mongoose_ws_clients`,
  `mongoose_active_streams`, `mongoose_executor_inflight`, and
  `mongoose_executor_queue_depth`. Health readiness wiring is still open
  (same seam, no consumer yet). *commit: `07c4a53`*
- [x] 8.7 `CHANGELOG.md` (Keep a Changelog + explicit 0.x breaking policy);
  deleted the dead `Performance.yml`. Tagging 0.5.0 and the GPL-2 decision are
  release-owner decisions, left open. *commit: `809fc79`*
- [~] 8.8 Parser fuzz-ish test shipped (400 random-byte rounds) and it found
  three real multibyte-indexing crashes (cookie/multipart/boundary) — fixed.
  Coverage upload, TLS matrix, and doctests remain open (need repo/CI setup).
  *commit: `4f96f0b`*

### Batch 9 — design & docs
- [x] 9.1 Endpoint-invocation protocol (`invoke_endpoint` /
  `endpoint_middleware`); custom routers carry their own endpoint type; the
  RegexRouter showcase and a custom-endpoint test prove the seam. *`07c4a53`*
- [x] 9.2 `services(req)` + `with_services(f, req)` (function-barrier typed
  access); `service` docs corrected — the Val form is convenient, not
  statically typed. *`07c4a53`*
- [x] 9.3 Decided: `App.context`/`executor` stay abstract-typed. It is one
  virtual call per request, an accepted trade-off recorded in DESIGN T6;
  parameterizing `App` would break the context rebuild on `service!`/`use!`.
- [x] 9.4 Parameterized `PathFilter{M}`, `Bearer{F}`, `RateLimit{F}`,
  `Logger{O}`, `SSEWriter{W}`. *`07c4a53`*
- [x] 9.5 `Headers` gained case-insensitive `delete!` and `push!(h, k, v)`;
  `getindex` stays silent-`nothing` (earlier decision). *`07c4a53`*
- [x] 9.6 `Response(status, body)` adds a default `Content-Type` for non-empty
  bodies (explicit CT never duplicated). Folding `StreamResponse.content_type`
  into headers is deferred (works today; churn not worth it now).
  *`07c4a53`*
- [x] 9.7 `Request(; method, uri, …)` keyword constructor. *`07c4a53`*
- [x] 9.8 Documented in api.md: `get!`/`put!`/`delete!` are Base extensions;
  the rest are Mongoose exports. *`07c4a53`*
- [x] 9.9 Drift fixed: compiled.jl auto-HEAD comment, DESIGN.md marked
  historical, FakeTransport doc/heading duplicates, `bake` test names.
  *`07c4a53`*
- [~] 9.10 `isrunning(server)` / `url(server)` shipped; unexporting
  `Tagged`/`Intent`/`PathFilter`/`MethodMap`/`sethandler!` is deferred — the
  facade uses them unqualified across layers and the churn is cosmetic.
  *`07c4a53`*
- [x] 9.11 Naming-conventions section in README (types/acronyms, functions,
  `!` mutators, predicates, teardown verbs by scope, capability traits).
  *`07c4a53`*
- [ ] 9.12 DEFERRED: decoding the path once at the adapter boundary changes
  route-matching semantics (routes would match decoded paths); needs its own
  design pass. Current behavior is documented.
- [ ] 9.13 Post-1.0 features (proxy headers, sessions/CSRF, OpenAPI, static
  Cache-Control, streaming request bodies, HTTP/2, permessage-deflate, FFI
  pin/self-check, optional CodecZlib) — unchanged, out of the 0.5 scope.

### Batch 10 — AOT / `juliac --trim` readiness (verified NOT compatible)
**Verification (Sep 23).** Built a minimal AOT app (`@main`, frozen router;
text/JSON/parsejson/typed-param/multipart/SSE/WS routes) with JuliaC on
Julia 1.13:
- `--trim=safe --experimental`: **fails the trim verifier with 62 unresolved
  calls**:
  - 32× runtime `apply_type` of compiled terminals
    (`Terminal{typeof(handler)}` built from `Endpoint.handler::Function` while
    scanning the Dict-based route table in `_bake_action`/`_compile_*`).
  - Executor lifecycle through the abstract `App.executor::AbstractExecutor`
    field (`start!`/`stop!`/`dispatch_replies!`/`supervise_workers!`).
  - Middleware normalization/stack: `asmiddleware(mw::Any)`,
    `attach!(::AbstractMiddleware, server)`, `PathFilter(...)`,
    `RequestContext(router, Tuple(vector)::Tuple{Vararg{AbstractMiddleware}}, …)`.
  - Route registration: `ParamRoute{P}(…, (types...,)::Tuple{Vararg{Type}})`,
    `_compile_param(::ParamRoute)::CompiledParam{P} where P<:Tuple`.
  - Closure-typed work: `(::Function)()` executor jobs, `convert(Function, …)`
    for `Dict{Int,Union{Response,Function}}` error handlers,
    `dispatch_event(::AbstractServer, …)`.
- `--trim=unsafe`: builds (2.9 MB exe) but **crashes at startup** —
  `MethodError: no method matching ParamRoute{P,N}(…)`: the parametric
  constructor was trimmed away because the call is invisible to the trimmer.
- `examples/aot/server.jl` (local) is stale: it uses removed
  `@router`/`fail!`/`context!` APIs.

**Design roadmap (leverage order).**
1. **Static route table (fundamental).** Put the table in a type parameter —
   `@routes`/`StaticRouter{Routes<:Tuple}` (macro or generated function) where
   endpoints carry concrete handler types and terminals are baked at
   registration instead of scanning a `Dict{String,FixedRoute}` at `freeze!`.
   Removes all 32 Terminal + both ParamRoute errors.
2. **Parametric `App`** — `App{R,E<:AbstractExecutor,M<:Tuple}` (or executor
   function barriers) so `executor::E` is concrete.
3. **Typed middleware stack** — accept a tuple at construction
   (`App(middleware=(cors(), compress()))`) baked into a type parameter; make
   `asmiddleware`/`attach!` generic over the concrete type, not
   `::Any`/`::AbstractMiddleware`.
4. **Typed jobs** — `submit!(exec, job::F) where F` + a job type instead of
   `Channel{Function}`; the SyncExecutor inline path then specializes.
5. **Error handlers** — replace `Dict{Int,Union{Response,Function}}` with a
   parametric handler type (or accept dynamic dispatch there explicitly).
6. **CI truth** — an `aot/` example + CI job that runs `juliac --trim=safe`
   and curls the binary; keep the README AOT claim only while green.

Status: **not trim-compatible**; README/docs/CHANGELOG claims corrected to
"foundation / in progress".

### Batch 11 — performance audit & baselines (Sep 23)
Measured per-op (Julia 1.13, warm, single thread, `@allocated`/`@elapsed`
loops): `process` frozen fixed **384 B / ~850 ns**; generic fixed 512 B /
~1600 ns; frozen param 720 B / ~1300 ns; generic param 896 B / ~2200 ns;
frozen + `cors()`+`etag()` 1440 B / ~1950 ns. Unit costs: `parse_method`
**272 B**; `parsequery("a=1&b=2")` **1088 B**; `Request(...)` 224 B;
`context(req)` 304 B; `mergeheaders` 368 B; `formatheaders` 336 B;
`asheaders(tuple)` 112 B. JET `report_opt` on `process`/`_resolve_terminal`/
`matchroute`/`runpipeline` found no reports at the analyzed signatures (the
dynamic work happens inside returned closures).

**Design flaws / missing patterns found.**
- [x] P1 `parse_method` — **fixed**: const tuple + byte compare, 0 B/op (was 272 B). *batch 12*
- [x] P1 `parsequery` + eager `Request.query` — **fixed**: `querydict(req)` parses on first access (one raw String, nothing for queryless requests). *batch 12*
- [x] P1 Metrics — **fixed**: fixed-size `Matrix{Int}` counters per shard, no string key. *batch 12*
- [x] P1 Pipeline — **fixed**: immutable `Next` callable for tuple stacks; the compiled path lost its per-request closure (64 B saved, ~2× on the onion microbench). *batch 12*
- [ ] P2 DI: with services registered, `process` eagerly allocates a
  `Dict{Symbol,Any}` and boxes the NamedTuple per request (304 B); typed DI
  via handler wrapping at registration is the clean fix (also the trim fix).
- [ ] P2 `Endpoint.handler::Function`, `WSEndpoint` callbacks, and `Channel{Function}` jobs — **Phase C1/C3** of batch 12.
- [x] P2 Per-connection values — **partly fixed**: peer IP cached per connection (`cached_remote_addr`, cleared on close); request-id still per request. *batch 12*
- [x] P2 Header assembly — **fixed**: one `IOBuffer` per response/stream head, no concatenation chains. *batch 12*
- [ ] P2 Generic parametric matching allocates `Vector{String}` per request;
  compiled dispatch avoids it — keep steering production users to `freeze!`
  and add an allocation assertion so it cannot regress.
- [ ] P3 `@nospecialize(handler::Function)` at registration guarantees a
  dynamic call on the generic path; documented trade-off, don't add more.
- [x] P3 Regression gate — **fixed**: tracked `bench/dispatch.jl` (BENCH_ASSERT ceilings), `test/unit/perf.jl` allocation + `@inferred` guards, advisory CI perf step. *batch 12*

**Deliverable:** `.opencode/skills/julia-performance/SKILL.md` — the working
performance checklist (rules, hot-path map, measured baselines, verification
commands, trim constraint, anti-patterns) for future sessions.

## Optimization plan (Batch 12) — performance-first redesign

Breaking changes are acceptable (0.5 window). Ordering principle: guardrails
first, then independent hot-path wins, then type-parameterization (which also
unblocks `juliac --trim`), then simplification. Every task lands with the
four gates plus before/after numbers in the commit message.

### Phase A — measurement & guardrails (no API change)
- [x] **A1** Track a `bench/` script (was deleted with `Performance.yml`):
  fixed/param × frozen/generic × middleware on/off, printing B/op and ns/op
  from warm `@allocated`/`@elapsed` loops. Baselines live in the
  `julia-performance` skill.
- [x] **A2** Allocation assertions in the test suite: `@allocated` ceilings for
  `process` on a frozen fixed route (target ≤ 384 B), frozen param (≤ 720 B),
  and the middleware tuple path (≤ 1 KB with cors+etag). Fail on regression.
- [x] **A3** `@inferred` tests for the hot helpers (`matchroute`, `getterminal`,
  `mergeheaders`, `asheaders`, `parse_method`, `statusreason`) and a JET
  `report_opt` baseline for `process`/`_resolve_terminal`.
- [x] **A4** CI job running A1–A3 with generous thresholds (advisory on macOS,
  blocking on ubuntu).

### Phase B — hot-path wins (localized, mostly internal)
- [x] **B1** `parse_method`: byte lookup table for the 7 methods instead of
  `lowercase(String)+Symbol`. Target: 272 B → ~0 B, ~200 ns → ~20 ns.
- [x] **B2** Query laziness: parse query on first `query()`/`req.query` access
  instead of eagerly in the adapter (`parsequery` costs 1088 B for 2 params).
  API: keep `query(req, …)`; make the eager `req.query::Dict` field a computed
  accessor (`querydict(req)`), or memoize into a `Ref`. Target: −1 KB/op on
  requests that ignore the query.
- [x] **B3** Metrics: replace `Dict{String,Int}` + `string(method,"_",status)`
  with a fixed-size `Matrix{Int}` (methods × status codes) per shard; keep the
  histogram as-is. Removes one String + dict growth per request and shrinks the
  locked section.
- [x] **B4** Pipeline: remove the per-request `_ChainCursor` + `next` closure;
  use a callable `Next` struct (subtype of `Function`) over the tuple stack so
  the onion is allocation-free. Keep the `(req, next)` middleware contract.
- [x] **B5** Transport header assembly with one `IOBuffer` per response
  (`send_http_response!` rid path, `_close_after_raw`, stream head).
- [x] **B6** Per-connection caches in the transport: remote-address string
  (currently formatted per request) and, if cheap, the request-id; cleared on
  `MG_EV_CLOSE`.
- [x] **B7** `start!` auto-`freeze!`s the router when registration is closed
  implicitly (registration after `start!` already throws), so production gets
  compiled dispatch without an extra call. Users can still pre-freeze.

### Phase C — type parameterization (also fixes `juliac --trim`)
- [x] **C1** `Endpoint{F}` / `WSEndpoint{M,O,C}` with the handler/callback types
  captured; `@nospecialize(handler::Function)` removed from registration so
  the types are actually captured. Generic path 320→304 B / 704→688 B; no
  regressions. *commit: (this one)*
- [x] **C2** `App{R,E<:AbstractExecutor}` with `executor::E`; executor barriers
  (`_init_executor!`, `_haspending`, `_dispatch_replies!`, `_stop_executor`)
  replace the `isa AsyncExecutor` branches. Construction goes through a
  `_build_app` type barrier (fixes a JET finding from `typeof(union)`).
  `App.context` stays one accepted dynamic hop (DESIGN T6); the transport
  callbacks take `AbstractServer` (C boundary). *commit: this one*
- [x] **C3** Typed executor jobs: `submit!(exec, job::F) where {F<:Function}`
  (sync specializes; async keeps the queue boxing). Ambiguity with the
  `AbstractExecutor` fallback fixed via the `F<:Function` bound. *commit: this
  one*
- [x] **C4** Typed DI: `Request.services` field set by `process` (208 B/op with
  services vs 192 without; was ~496 with the eager Dict). `service`/
  `services`/`withservices` read the field; `context(req)` is user-data-only.
  *commit: (this one)*
- [x] **C5** `Endpoint{F,M<:Tuple}` stores scoped middleware as a captured
  tuple (`asmiddlewaretuple`); compiled scoped wrappers run through the
  allocation-free `Next` pipeline. Scoped routes: 192 B/op (was +80 B + a
  closure); generic fixed 304→256 B, param 688→640 B. `PathFilter` still
  wraps prefix-scoped global middleware (D1 candidate). *commit: this one*
- [ ] **C6** `@routes`/`StaticRouter{Routes<:Tuple}` for AOT: compile-time
  route table with concrete handler types, terminals baked at registration;
  `freeze!` returns the compiled router (or builds `StaticRouter`), removing
  runtime `apply_type` (`Terminal{typeof(handler)}`, `ParamRoute{P}`). This is
  the batch-10 enabler; document the dynamic `Router` as the dev path.

### Phase D — simplification & maintenance
- [x] **D1** `MethodMap` uses explicit per-method branches (no dynamic
  `getfield`/`setfield!` symbol lookup); `getendpoint` docstring restored.
  Kept: `PathFilter` (prefix-scoped global middleware), `SingleEndpoint`
  (custom-router carrier), and the Kernel-exported internals (`Tagged`,
  `Intent`, `MethodMap`) as the documented extension surface.
  *commit: this one*
- [x] **D2** `docs/src/performance.md` added (measured baselines, production
  recipe, observability, regression guards, AOT/trim status) and linked from
  the docs index + sidebar. *commit: this one*
- [x] **D3** `julia-performance` skill refreshed: current baselines, typed-
  struct list (`App{R,E}` included), MethodMap note, fixed anti-patterns.
  *commit: this one*

### Acceptance targets
- Frozen fixed route: ≤ 200 B/op, ≤ 400 ns/op (from 384 B / ~850 ns).
- Frozen param route: ≤ 400 B/op, ≤ 700 ns/op (from 720 B / ~1300 ns).
- Frozen + cors+etag: ≤ 800 B/op (from 1440 B).
- `juliac --trim=safe` builds the AOT example and serves requests (from 62
  verifier errors / startup crash).
- No non-const globals, no `@nospecialize` on public registration, no
  `::Function` fields in stored callables.

## Changelog

- **Sep 17 — SIGTERM mechanism corrected**: the custom C handler added in
  batch 8 was dead code — Julia blocks SIGTERM process-wide (`SigBlk` bit 15)
  and handles it in its runtime, which runs `atexit` callbacks. Graceful
  shutdown on SIGTERM/exit therefore goes through `atexit(_shutdown_registered!)`
  (drain + `onstop!`); the flag/handler were removed. The acceptance child
  test now proves the hook with a marker file (the stdout-pipe race caused
  the macOS CI failure) and no longer asserts a zero exit status, since Julia
  terminates with the signal status by design.
- **Sep 17 — Public-name standardization (final naming pass)**: audited the
  whole exported surface and removed the last four underscores
  (`ws_send_all`→`broadcastws`, `with_services`→`withservices`,
  `invoke_endpoint`→`invokeendpoint`, `endpoint_middleware`→
  `endpointmiddleware`), fixed acronym casing (`WsConn`/`WsEndpoint`→
  `WSConn`/`WSEndpoint`), and made every middleware builder the lowercase name
  of its type (`PrometheusMetrics`→`Metrics`, `SecurityHeaders`→`Security`).
  README naming conventions now document the rules and exceptions; DI docs use
  `withservices`; metrics docs list the gauges. Inventory: 127 facade names,
  zero underscores; Kernel extension names also underscore-free. 3550 tests +
  81 acceptance + Aqua/JET baseline + docs green.
- **Sep 17 — Batch 9 (design & docs) shipped** (`07c4a53`): endpoint
  invocation protocol for custom routers; `services`/`with_services` typed DI
  access; `attach!` seam with metrics gauges; parameterized hot structs;
  `Headers.delete!`/`push!(k,v)`; `Request` keyword constructor;
  `isrunning`/`url`; `Response` default Content-Type; naming-conventions
  section and doc-drift fixes. 3550 tests + 81 acceptance + Aqua/JET baseline
  + docs green. Deferred: 9.12 (path decode at the adapter), health
  readiness, post-1.0 features.
- **Sep 17 — Batch 8 (CI / ops / release) shipped**: CI gates acceptance +
  quality on every branch with a failing JET baseline (`809fc79`); SIGTERM +
  atexit graceful shutdown, `header_timeout_ms`/`max_connections`, verified
  8 MiB receive ceiling with config validation, sync-timeout warning, and a
  parser fuzz test that caught three multibyte indexing crashes (`4f96f0b`).
  3519 tests + 81 acceptance + Aqua/JET baseline + docs green. Remaining:
  8.6 (metrics/health attach seam) folded into batch 9; coverage/TLS
  matrix/doctests open.
- **Sep 17 — Batch 7 (lifecycle & concurrency) shipped** (`c021fa7`):
  locked + pruned `bg_tasks`; bounded `stop!` that drains replies; streams
  counted in drain with a final flush; `Threads.@spawn` producers; WS
  generation ids; always-reply job errors; hostile chunk-size guards. 1105
  tests + 80 acceptance + Aqua/JET + docs green. Next: batch 8 (CI/ops).
- **Sep 17 — Batch 6 (P0 + P1 hotfix) shipped**: chunked requests fixed
  (`7997167`); CORS preflight detection, case-insensitive Connection echo,
  SameSite=None + cookie/redirect CTL rejection, WS idle units + force close +
  upgrade handshake guard, `ws_send_all` export, 400/415 body errors,
  segment-aware `paths=`, logger 500s (`db56dce`). 1088 tests + 80 acceptance
  + Aqua/JET + docs green. Next: batch 7 (lifecycle & concurrency).
- **Sep 17 — Audit (deep review) delivered**; findings + batches 6–9 recorded
  above. Batch 6 (P0 + P1 hotfix) starts next.
- **Sep 17 — Batch 5 (surface coherence) shipped**: the read-side router
  protocol now lives on the server too — `freeze!(app)`, `isfrozen(app)`,
  `length(app)`, `matchroute(app, …)`, `hasroute(app, path)`,
  `haswsroutes(app)`, `getwsendpoint(app, uri)` delegate to `app.router`
  (mutation was already server-level); `AbstractServer` is now exported and
  documented. Framework-emitted headers use canonical casing (`Content-Type`
  on thrown-HTTPError defaults, `ETag` from the etag middleware; user headers
  still pass through as given). `Logger` reads `X-Request-Id` through
  `get(headers, …)`. `ServiceRegistry` is non-parametric and `App.services`
  is a `const` field (mutated in place by `service!`) — the last non-const
  build-phase field. 1058 tests + 80 acceptance + Aqua/JET + docs green.
  All audit batches (1–5) are now shipped.
- **Sep 17 — Batch 4 (units + kwarg names) shipped**: every quantity carries
  its unit in the name — `_ms` (`poll_timeout_ms`, `drain_timeout_ms`,
  `request_timeout_ms`, `ws_idle_timeout_ms`, `logger(threshold_ms=…)`,
  `emit(…; retry_ms=…)`), `_seconds` (`window_seconds`, `cors(max_age_seconds=…)`,
  `security(hsts_max_age_seconds=…)`), `_bytes` (`max_body_bytes`,
  `ws_max_frame_bytes`, `compress(min_size_bytes=…)`); `queuesize` →
  `queue_size`; constants `MAX_BODY_BYTES`/`DRAIN_TIMEOUT_MS`. `cors(methods=,
  headers=)` → `allow_methods=`/`allow_headers=`. `security()` "off" is now
  uniformly `nothing` (was 0/""/false; `csp` defaults to nothing).
  `Cookie(; max_age=…)` keeps its spec name (documented exception). Unit table
  added to README + docs index. 1041 tests + 80 acceptance + Aqua/JET + docs
  green.
- **Sep 17 — Batch 3 (naming decisions) shipped**: `json(req)` → `parsejson(req)`
  (the old method throws a migration `ArgumentError`); `WrongMethod` →
  `NotAllowed`; `wsendpoint` → `getwsendpoint` (+ protocol docstrings for it and
  `haswsroutes`); `TestClient` alias removed (canonical: `FakeTransport`);
  `bake` → `setcookie`; zero-arg `shutdown!()` removed (unused kill-switch);
  added `BadGatewayError`/`ServiceUnavailableError`/`GatewayTimeoutError`.
  Verb split documented: server `start!`/`shutdown!`, executor
  `start!`/`stop!`, transport/streams `close!`. 1035 tests + 80 acceptance +
  Aqua/JET + docs green.
- **Sep 17 — Batch 2 (registration conventions) shipped**: `onstart!` /
  `onstop!` / `background!` / `onerror!` are app-first with `(f, app, …)`
  do-block sugar (loosened to `AbstractServer`); the trap 3-arg
  `serve!(app, prefix, dir)` is gone (prefix is keyword-only); `ws!` accepts
  the handler positionally on server/router/group alongside `on_message=`;
  `validate(req, T; on_error=…)` receives the whole `ValidationError`
  (do-block sugar kept). 1031 tests + 80 acceptance + Aqua/JET + docs green.
  Batches 3–5 (naming decisions, units table, App-level introspection) remain.
- **Sep 17 — Batch 1 (input normalization) shipped**: new Kernel normalizers
  `asheaders` / `asstrings` / `asmiddlewares` (+ `Headers(pair)`/`Headers(tuple)`/
  `Headers([])`). `headers=` now accepts `Headers`/pair/tuple/vector in
  `Response`, typed-format `Response`, `json`/`html`/`text`/`redirect`,
  `StreamResponse`, `sse`, `Request`, and `TestClient`; `middleware=` accepts
  nothing/single/tuple/vector in `route!`, `Endpoint`, `group`, `group!`;
  `paths=` and `allowed_origins=` accept single/vector/tuple/SubString;
  `cors(origins=…)` likewise. `route!`/`matchroute` normalize method case
  (`:GET`, `"GeT"`), and `mount!`/`start!` return the server. 1015 tests + 80
  acceptance + Aqua/JET + docs green. Audit batches 2–5 (registration order,
  naming decisions, units table, App-level router introspection) still pending.
- **Sep 17 — P1 ergonomics batch shipped** (`f52b763`, `9440686`, `a622c83`):
  `mergeheaders` (non-mutating header merge, 7 rebuild sites deleted),
  `apikey` positional/collection builder, `shutdown!` drains `bg_tasks`
  (bounded + pruned), 413/503 carry `X-Request-Id`. 939 tests + 80
  acceptance + Aqua/JET + docs green. Remaining P1: the three decisions
  (Headers.getindex, json(req) overload, unit-convention table).
- **Sep 08 — Phase 1 kickoff.** Decisions recorded above.
- **T1 shipped** (`ffaf1e1`): unified Headers; 763 tests + 71 acceptance +
  Aqua/JET green.
- **T2 shipped** (`94c3b27`): auto-serialize; 780 tests + 71 acceptance +
  Aqua/JET green.
- **T3 shipped** (`165fffc`): RouteResult ADT / matchroute; 787 tests + 71
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
  instead. Docs: `HTTPError`/`errorstatus` added to api.md Errors section.
- **T6 shipped** (`5d72d9e`): RequestContext seam. 811 tests + 73 acceptance
  + Aqua/JET + docs green. `process(ctx, req)` is the single pipeline
  seam; typed-exception dispatch + HTTPError/ValidationError mapping moved from
  the transport into core. `invoke_guarded` DELETED (its logic is now inside
  `process`). App gained a `context::RequestContext` field mirroring its
  live containers (mutable Dict/Vector refs are shared, so `use!`/`onerror!`
  need no context refresh — only `service!` rebuilds it, since services are a
  snapshot NamedTuple). Trade-off accepted: `App.context` is abstract-typed →
  one virtual call per request on the seam (frozen hot path pays ~1 indirect
  call); kept `App` parametric in `R` only for API stability.
- **T7 shipped** (`50d1c93`): middleware = plain callable; `before`/`after`
  protocol deleted. 811 tests + 73 acceptance + Aqua/JET + docs green. Only one
  `after` user existed (`SecurityHeaders` → call operator); no `before`
  overrides anywhere. `before`/`after` dropped from MongooseCore exports;
  `asmiddleware` docstring added (and to api.md).
- **T8 shipped** (`716e9d4`): baked-tuple global middleware. 811 tests + 73
  acceptance + Aqua/JET + docs green. `RequestContext.middlewares` is a Tuple
  (baked at construct; `use!`/`service!` re-snapshot). `runpipeline` gained
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
- **Sep 09 — T10 deferred.** Plugin lifecycle is API-without-usage; the
  rollback rationale doesn't apply because `start!` logs-and-continues on hook
  failure. Same criteria as T9/T4: defer until a real plugin exists.
- **Sep 09 — gate-sweep items (proposal batch):**
  - **Leak fix** (`1dcd040`): `_http_job_timed` now tracks its over-budget task
    in `server.runtime.bg_tasks` instead of dropping it silently. Test pins it
    (with `retry=false` — HTTP.jl retries the 504 four times, which was
    doubling bg_tasks in the earlier probe).
  - **ETag middleware shipped** (this commit): `etag()` — strong FNV-1a ETags
    over buffered response bodies (deterministic, no new deps; crypto is not
    needed for a cache validator) + If-None-Match (304 GET/HEAD, 412 otherwise,
    weak `W/` comparison, `*`) + If-Match (412, strong). Applies to `Response`
    only (raw returns are serialized after the pipeline); register outside
    `compress` so the tag validates what is sent. Acceptance: 73 → 79 checks.
  - **100-continue verified** (no code): this Mongoose JLL omits the interim
    `100 Continue` but fully accepts `Expect: 100-continue` requests — no 417,
    no hang, body delivered (verified with curl, incl. `--expect100-timeout`
    waiting clients). Legal per RFC 7231 §5.1.1 (server MAY omit). Strikes the
    "explicit reply" Phase-5 item.

## Review pass (Sep 09/10) — full-package audit + P0 remediation

Full honest review delivered to the user (strengths/weaknesses/ergonomics/
prod-readiness). State saved — **next session starts here:**

### Shipped in this pass
- **P0-truth** (`e5d877e`): facade export parity + doc-truth + dead-code sweep.
  - Killed: duplicate dead App docstring block `server/core.jl` (the real one
    at the struct attaches — verified via `Base.Docs.meta` Binding lookup);
    orphans `register_group!` (AGENTS.md claimed it was gone — wasn't),
    `has_any_handler`, `_allow_header`, `adapt_request_minimal`.
  - Doc rot fixed: `transport.jl` contract text now describes reality (trait
    seam + real C entry points + T9 deferral); `metrics.jl` example uses
    `App(workers=4)`; README `headers_get`→`get(req.headers,...)`; README/docs
    `MongooseTransport` (never existed) removed.
- **P0-export-correction** (`c7ed60c`): the parity pass over-exported ~45
  protocol/internal names — **user called it out, rightfully**. Policy now:
  facade exports = application surface only (pre-existing curated list +
  `group!` + `AbstractMiddleware`). Extension protocols stay MongooseCore-
  exported, reachable as `Mongoose.<name>` / `import Mongoose: <name>` (tests
  and pluggable-router showcase already use this). api.md has a
  Public-vs-Extension note; `@docs` entries resolve via namespace (docs green).

### Counts after the pass
- 875 tests (main + streaming), 79 acceptance checks, Aqua+JET clean, docs green.

### Pending (decide tomorrow, in order)
1. **Protocol getter rename** — DONE in batch 3: `wsendpoint`→`getwsendpoint`
   (`length(router)` stays as the `Base.length` integration; the rest of the
   getter family was already `get*`).
2. **P1 ergonomics** (from the review):
   - [x] `mergeheaders` helper replacing the 7 × `Headers([copy(h.data); …])`
     rebuild sites (cors/security/compress×2/etag/handler/testing) —
     non-mutating, concatenation semantics (duplicates/order preserved),
     `prepend=true` for middleware-wins sites. Kernel extension surface,
     documented + tested. *commit: `f52b763`*
   - [x] `apikey(keys; header_name=…)` positional builder; accepts a single
     string, `Set`, or `Vector`, normalized to `Set{String}`; keyword form
     unchanged. *commit: `9440686`*
   - [x] `shutdown!` waits on `bg_tasks` (one shared `drain_timeout` grace
     after `stop!(executor)`, then prunes finished tasks; never-ending
     `background!` loops are bounded, not joined); 413/503 early responses
     carry `X-Request-Id` (413 echoes the client id when present). *commit:
     `a622c83`*
   - [x] Decide `json(req)` parse-vs-serialize overload footgun — batch 3:
     parsing moved to `parsejson(req)`; `json(req)` throws a migration error.
   - [x] Decide `Headers.getindex(h, key)` → `nothing` semantics (vs KeyError).
     **kept silent `nothing`** (header lookup is optional by nature; `get` with a
     default remains the explicit form).
   - [x] Unit-convention table (ms vs seconds) + `security()` off-conventions —
     batch 4: `_ms`/`_seconds`/`_bytes` suffixes applied, off = `nothing`,
     table in README/docs; `Cookie.max_age` documented as a spec-name exception.
3. **P2 prod-readiness** (larger): CI wiring for acceptance+quality
   (nothing gates this branch today — runs only on main), OpenAPI-from-
   metadata (Endpoint.metadata is already plumbed — flagship 1.0 feature),
   sessions/CSRF, HTTP/2 decision + test, streaming body reads (bodies are
   fully buffered today), benchmark gate for the frozen-dispatch ns claims
   (Performance.yml exists, currently empty of benchmarks).

### Verified non-issues (don't re-litigate)
- Group `ws!` kwargs work — `values(Base.Pairs)` → NamedTuple, splats fine
  (the explore agent's "K7 bug" was a false positive).
- `App` does HAVE a docstring (the DESIGN-G4 one); only the duplicate block
  was dead.
- `tryput!` does NOT exist in Julia 1.12 Base → `signal(::Channel)` helper in
  test/helpers.jl.