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
- **`StaticRouter` + `@router`** — compile-time typed route table: fixed paths,
  typed params (`:id::Int`), wildcards, and route-scoped middleware, all as type
  parameters. Dispatch is fully static, with no per-request route lookup or
  dynamic terminal; the trim-safe routing profile.
- `App` is immutable and typed: `use(app, mw; paths)` and `provide(app, name, value)`
  return a rebuilt `App`; middleware and DI services live in the context type.

### Changed
- **Breaking**: `onerror!` returns the rebuilt `App` (rebind the result). Dynamic
  error and exception handlers are stored as typed tuples, making error handling
  statically resolvable.
- `StreamResponse{P}` is parameterized on its producer function.

### AOT
- `juliac --trim=safe` builds a working executable with the `StaticRouter`
  profile: 0 trim-verifier errors (`bench/trim/trim_core.jl`).

## [0.4.0] and earlier

Earlier releases predate this changelog.
