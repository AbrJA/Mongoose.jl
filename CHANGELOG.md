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

### Fixed
- **Chunked requests no longer hang** (P0): the adapter re-decoded Mongoose's
  already-decoded body through an unbound name, so every `Transfer-Encoding:
  chunked` request died with `UndefVarError` and no response.
- CORS only treats a real preflight (`OPTIONS` + `Origin` +
  `Access-Control-Request-Method`) as a preflight; bare `OPTIONS` reaches the
  route again, and `Vary: Origin` is emitted for denied origins too.
- `Connection: close` detection is case-insensitive and token-aware (the echo
  was missed for `Connection: Close`, wedging pooling clients).
- `SameSite=None` is emitted; CRLF/control characters are rejected in cookie
  fields, `setcookie`, and `redirect` locations.
- WebSocket idle timeout compares milliseconds correctly (~1000× too late
  before), sweeps every second, and force-closes unresponsive peers; `on_open`
  and registration only run for a real upgrade handshake.
- Malformed JSON → 400 and wrong `Content-Type` for `form`/`multipart` → 415
  (previously 500).
- `use!(paths=…)` matches whole path segments (`/api` no longer covers
  `/apixyz`) and normalizes trailing slashes.
- Graceful shutdown now drains active SSE streams to completion, bounds the
  executor join, prunes tracked background tasks, and flushes final bytes.
- WebSocket replies route by monotonic connection id, so a stale worker reply
  cannot be delivered to a different client reusing a connection address.
- `Logger` access-logs throwing handlers as 500 and writes each line atomically.

### Changed
- Naming/ergonomics normalization (0.5 window): unit-suffixed kwargs
  (`*_ms`/`*_seconds`/`*_bytes`), `cors(allow_methods=, allow_headers=,
  max_age_seconds=)`, `security()` disabled with `nothing`, app-first
  registration, `serve!(app, dir; uri_prefix=)`, `ws!(app, path, handler)`,
  `validate(req, T; on_error=)`, `parsejson`, `NotAllowed`, `getwsendpoint`,
  `setcookie`, `FakeTransport`, `mergeheaders`/`asheaders`/`asstrings`/
  `asmiddlewares`, App-level router introspection (`freeze!(app)` …).
- Header/path/middleware/origin inputs accept `Headers`, tuples, single
  strings, and vectors uniformly.
- `stop!(AsyncExecutor; timeout)` is bounded and drains replies while joining.

### Added
- `BadGatewayError`, `ServiceUnavailableError`, `GatewayTimeoutError`.
- `mg_close_conn` binding for force-closing idle WebSocket peers.

## [0.4.0] and earlier

Earlier releases predate this changelog. See `WORKLOG.md` for the detailed
history of the modular/hardening series.
