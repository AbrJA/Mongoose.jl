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
- `App()` sync, `App(N)` async (N-worker pool), `App(executor=…)` explicit
  injection: the executor is a first-class argument, so every construction
  infers one concrete `App` type without relying on constant propagation.
  `AsyncExecutor(n)` gets a one-arg convenience constructor.
- `health(; health_path=, ready_path=, live_path=)` custom probe paths;
  `nothing` disables an endpoint (e.g. a single `/health`).
- `App` is immutable and typed: `use(app, mw; paths)` and `provide(app, name, value)`
  return a rebuilt `App`; middleware and DI services live in the context type.

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
  profile (0 verifier errors): the full pipeline over `FakeTransport`
  (`bench/trim/trim_core.jl`) and a real server on the C transport
  (`bench/trim/trim_server.jl`). The AOT profile runs the event loop inline
  (trimmed exes cannot run tasks) and is sync-only.

## [0.4.0] and earlier

Earlier releases predate this changelog.
