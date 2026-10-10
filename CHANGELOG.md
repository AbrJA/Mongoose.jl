# Changelog

All notable changes to Mongoose.jl are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

> **Versioning policy.** During the `0.x` series, minor releases may contain
> breaking changes (no deprecation aliases) — the API is being normalized ahead
> of 1.0. Patch releases are bug fixes only. Every release ships with the
> gates: main suite, wire-level acceptance suite, Aqua + JET baseline, and a
> green docs build.

## [Unreleased]

### Added
- **`StaticRouter` + `@routes`** — compile-time typed route table: fixed paths,
  typed params (`:id::Int`), wildcards, and route-scoped middleware, all as type
  parameters. Dispatch is fully static, with no per-request route lookup or
  dynamic terminal; the trim-safe routing profile.
- `@routes` groups: `group("prefix"; middleware=…) do … end` is expanded at
  compile time (paths prefixed, middleware tuples concatenated), so grouped
  routes stay fully static.
- `@routes` WebSocket endpoints: `ws("path", handler; on_open=, on_close=,
  allowed_origins=)` declares typed WS routes; upgrade, message, and close
  dispatch resolve the concrete handlers (trim-safe, sync mode).
- `App()` sync, `App(N)` async (N-worker pool), `App(executor=…)` explicit
  injection: the executor is a first-class argument, so every construction
  infers one concrete `App` type without relying on constant propagation.
  `AsyncExecutor(n)` gets a one-arg convenience constructor.
- `health(; health_path=, ready_path=, live_path=)` custom probe paths;
  `nothing` disables an endpoint (e.g. a single `/health`).
- `App` is immutable and typed: `use(app, mw; paths)` and `provide(app, (name = value,))`
  return a rebuilt `App`; middleware and DI services live in the context type.

### Fixed
- **Dispatch parity across `Router`, `freeze!`-compiled, and `StaticRouter`**:
  a typed capture that fails to parse answers `400` only when the whole pattern
  structurally matches (`/users/abraham` against `/users/:id::Int/posts` is a
  `404`), and a `*` catch-all that owns the path answers `405` (not `400`) when
  it does not serve the method. `hasroute(router, "*")` no longer reports the
  catch-all as an owned path.
- Unknown route parameter types (`/u/:id::UUID`) now throw `RouteError` at
  registration instead of silently degrading to a `String` capture — in both
  `route!` and `@routes`.
- Unknown HTTP methods (`BREW`, `PROPFIND`, …) no longer fail with a `500` on
  the generic/static dispatch paths: all three dispatchers now answer `405`
  with the path's `Allow` set when the path is served and `404` otherwise,
  matching the compiled path. Mixed-case method `Symbol`s (`:GET`) normalize
  consistently everywhere.

### Performance
- Allocation-free ASCII case-insensitive matching: `Headers.get`/`haskey`,
  `header()`, `Bearer` scheme checks, and `Connection: close` token parsing no
  longer allocate `lowercase`/`split` copies (512–640 B → 0 B per lookup or
  request). `PathFilter` precomputes its prefix joins; the single-pair
  `mergeheaders` path is one allocation smaller.
- The generic dispatch path resolves matches through a parametric
  `EndpointCall` terminal with the compiled-terminal resolution split out
  (fixed: 224 → 208 B/op; parametric: 672 → 640 B/op; frozen parametric:
  544 → 528 B/op).
- Added a randomized differential test suite (16 generated tables × all
  methods × 24 probe paths) asserting identical `(status, body, Allow)` across
  the generic, compiled, and static routers.

### Changed
- **Breaking**: `App(workers=n)` is now `App(n)`; `App(workers=0)` is `App()`
  and `App(0)` is an error. `queue_size` stays a keyword on `App(n; …)`.
- **Breaking**: `trap` returns the rebuilt `App` (rebind the result). Dynamic
  error and exception handlers are stored as typed tuples, making error handling
  statically resolvable.
- **Breaking**: `@router` renamed to `@routes` — it declares the route table;
  `Router()` remains the runtime-registered default.
- **Breaking**: `onstart!`/`onstop!`/`background!` are now
  `onstart`/`onstop`/`background` and return the rebuilt `App` (lifecycle hooks
  are stored as typed tuples, so hook dispatch is statically resolvable).
- Transport capability traits renamed to explicit names:
  `supportsws`/`supportstls`/`supportsstream` (were `canws`/`cantls`/`canstream`).
- `StreamResponse{P}` is parameterized on its producer function.
- `StaticRoute` is no longer exported; it is constructed by `@routes`.

### AOT
- `juliac --trim=safe` builds working executables with the `StaticRouter`
  profile (0 verifier errors): the full pipeline over `FakeTransport` and a
  real server on the C transport. The AOT profile runs the event loop inline
  (trimmed exes cannot run tasks) and is sync-only. Local reference builds
  live under `examples/aot/` (gitignored).

## [0.4.0] and earlier

Earlier releases predate this changelog.
