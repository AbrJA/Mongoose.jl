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
- **Log-injection hardening**: the plain-text access logger replaced control
  bytes in the request target (a hostile URI could forge log lines or inject
  terminal escapes); structured mode already escaped them.
- **ABI sanity check**: on the first request the server verifies the pinned
  Mongoose struct offsets against the running build (accepted flag, header
  length, address family byte) and logs a loud error once instead of silently
  mis-reading connection state on an unsupported platform.
- **WebSocket pushes are bounded and non-blocking**: a slow reader used to grow
  the connection's send buffer without bound (measured: 20 MB buffered for
  20 MB of pushes) and `broadcastws` stalled on the bounded reply queue
  (measured: 5.7 s for 20k frames). Pushes now respect `send_buffer_bytes`
  (formerly `stream_buffer_bytes`, now covering streams **and** WS) and are
  dropped with a `mongoose_ws_frames_dropped` gauge when the queue is full or
  the cap is reached (measured: 0.02 s, buffer pinned at the cap).
- **Producer-side channel checks**: `_offer_reply!`/the example EventBus used
  `isready` (a *consumer* predicate) to test put-ability, silently dropping
  every queued reply/event. Both now compare `Base.n_avail` to capacity.
- **Static file serving no longer exposes dotfiles** (`.env`, `.git`, …);
  `.well-known` stays allowed (ACME/`security.txt`). Path checks now decode
  percent-escapes first, so encoded traversal and encoded dotfiles are
  blocked too. (Symlinks inside a mount are still followed by the OS — do
  not place links that escape the root.)
- **IPv6 binds actually work**: `host="::1"` (or `"::"` for dual-stack) was
  passed unbracketed into the listen URL, so the C parser bound nowhere
  useful. URLs are now `[::1]:port`; HTTP.jl and dual-stack verified.
- **Metrics count handler exceptions**: 500s (and `HTTPError` statuses) were
  invisible to `http_requests_total`/the histogram because the exception
  bypassed the response path. Exceptions are now recorded as
  `errorstatus(e)` or 500.
- **Streaming responses apply backpressure**: at most `stream_buffer_bytes`
  (default 1 MiB) of unsent data is buffered per connection. Previously a
  slow SSE reader could grow server memory without bound and stall the event
  loop while the producer drained into Mongoose's send buffer.
- **Error responses are no longer mutated across requests**: the shared
  `DEFAULT_*` error pages had `Connection`/`Retry-After` appended in place
  (headers accumulated). Header additions are copy-on-write now.
- **Critical — connection-close paths leaked the fd and could wedge the
  event loop**: the max-connections refusal, the `header_timeout_ms` sweep,
  and the WS idle close called `mg_close_conn`, which frees the connection
  struct without closing the socket or removing it from the epoll set. Each
  call leaked a descriptor and left a dangling epoll registration; a burst
  (or a single slowloris) could spin/wedge the server permanently. All three
  now use `mg_error` (mark closing; the poll loop runs the real close path)
  or `mark_draining!` when queued output must flush first.
- **Async `Connection: close` is honored**: Mongoose only sets `is_draining`
  when a *synchronous* handler replies inside the callback; pool replies are
  sent after it returns, so the header was echoed but the socket stayed open.
  The reply path now marks the connection draining once the response is
  queued, and the socket closes after the flush.
- **`header_timeout_ms` no longer kills slow request bodies**: the
  slowloris watch is cleared at `MG_EV_HTTP_HDRS` (headers complete), so a
  legitimate upload longer than the timeout is served, while incomplete
  headers are still reclaimed.
- **Oversized `Content-Length` gets an early, clean 413** (before the body is
  buffered). The reply advertises `Connection: close` and the socket closes
  after the upload finishes, so clients mid-write see the 413 instead of a
  reset.
- **WebSocket control frames are answered once**: Mongoose already auto-replies
  to PING (PONG) and CLOSE (echo + drain); the control handler was sending a
  second reply. It now only updates keep-alive bookkeeping.
- `MG_EV_HTTP_HDRS` was missing from the handled-event allowlist, so the
  headers-complete event never reached the handler.
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
- `request_timeout_ms` now bounds the **client's** wait only: timed-out
  handlers cannot be killed (Julia tasks are cooperative), so they are
  abandoned and tracked. `max_bg_tasks` (default auto: 4×workers) caps the
  runaways; once reached, new timed requests are shed with `503` +
  `Retry-After` instead of exhausting the thread pool. The
  `mongoose_bg_tasks` gauge exposes the current count. Handlers should be
  self-bounding (DB/HTTP client timeouts) for real resource limits.
- `send_buffer_bytes` (default 1 MiB, 0 = unlimited; renamed from
  `stream_buffer_bytes`) caps unsent data per connection for **streams and
  WebSocket pushes**; queue-full and shed `503`s carry `Retry-After: 1`.
- New hardening knobs: `body_timeout_ms` (0 = disabled) bounds how long a
  client may take to deliver a request body, and `max_header_bytes`
  (default **64 KiB**, 0 = unlimited) caps request headers — oversized
  complete headers get a clean 431, incomplete ones are dropped before more
  is buffered. The 64 KiB default is stricter than before (the old bound was
  Mongoose's 8 MiB receive ceiling).
- Public-name standardization: `ws_send_all` → `broadcastws`,
  `with_services` → `withservices`, `invoke_endpoint` → `invokeendpoint`,
  `endpoint_middleware` → `endpointmiddleware` (no underscores anywhere on
  the public surface); `WsConn`/`WsEndpoint` → `WSConn`/`WSEndpoint` (acronym
  casing); `PrometheusMetrics`/`SecurityHeaders` → `Metrics`/`Security` so
  every middleware builder is the lowercase name of its type.
- Naming/ergonomics normalization (0.5 window): unit-suffixed kwargs
  (`*_ms`/`*_seconds`/`*_bytes`), `cors(allow_methods=, allow_headers=,
  max_age_seconds=)`, `security()` disabled with `nothing`, app-first
  registration, `serve!(app, dir; uri_prefix=)`, `ws!(app, path, handler)`,
  `validate(req, T; on_error=)`, `parsejson`, `MethodMismatch`,
  `getwsendpoint`, `setcookie`, `FakeTransport`, `mergeheaders`/`asheaders`/
  `asstrings`/`asmiddlewares`, App-level router introspection (`freeze!(app)` …).
- Naming pass 2 (0.5 window): parsers unified as `parse*` — `parseform`,
  `parsemultipart`, `parsecookies`, and `querydict` folded into
  `parsequery(req)`; `terminalfor` → `getterminal`, `endpointmiddleware` →
  `scopedmiddleware`; transport capability traits `supportsws`/`supportstls`/
  `supportsstream` → `canws`/`cantls`/`canstream` (routers keep
  `haswsroutes`).
- Header/path/middleware/origin inputs accept `Headers`, tuples, single
  strings, and vectors uniformly.
- `stop!(AsyncExecutor; timeout)` is bounded and drains replies while joining.

### Added
- Base integrations: `isempty(::Router)` / `isempty(::App)`,
  `keys`/`values`/`pairs` on `Headers` (ordered, duplicates preserved), and
  terse one-line `show` for `Request`, `Response`, and `StreamResponse`.
- `FakeExecutor` and `run!` are now exported from the facade (previously
  `Mongoose.Kernel`-only), matching `FakeTransport` as the testing doubles
  for the two extension seams.
- Complete `HTTPError` alias coverage for 400–511 (incl. `ProxyAuthRequiredError`,
  `MisdirectedRequestError`, `RequestHeaderFieldsTooLargeError`,
  `HTTPVersionNotSupportedError`, `VariantAlsoNegotiatesError`,
  `InsufficientStorageError`, `LoopDetectedError`, `NotExtendedError`,
  `NetworkAuthRequiredError`) plus `statusreason` for the full range.
- `BadGatewayError`, `ServiceUnavailableError`, `GatewayTimeoutError`.

### Known limitations
- **AOT/`juliac --trim` is not supported yet.** `freeze!` and the compiled
  route table are the foundation, but a real `--trim=safe` build currently
  fails the verifier (62 unresolved dynamic calls in startup/registration) and
  a `--trim=unsafe` build crashes constructing a parametric route. The
  required design work is tracked in `WORKLOG.md`.
- **TLS is 1.3-only** (Mongoose's built-in TLS in the `Mongoose_jll` build).
  TLS 1.2 clients cannot connect; terminate at a reverse proxy or rebuild the
  JLL with OpenSSL. Setting `TLSConfig.ca` enables mutual TLS (a client
  certificate is then required). Stalled TLS handshakes are only reclaimed
  when `header_timeout_ms` is set.
- **Unmasked WebSocket client frames are tolerated**: Mongoose's frame parser
  does not enforce RFC 6455 §5.1 client masking. Browsers always mask, and
  there is no server-side security impact; an enforcing parser would have to
  bypass the C layer.

## [0.4.0] and earlier

Earlier releases predate this changelog. See `WORKLOG.md` for the detailed
history of the modular/hardening series.
