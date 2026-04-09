# Roadmap

Planned features and improvements for Mongoose.jl. Items are listed in rough priority order within each category.

## WebSocket

- [ ] **Subprotocol negotiation** — `Sec-WebSocket-Protocol` header support in `ws!` / `on_open`.
- [ ] **Broadcast / rooms** — server-initiated push to groups of connected clients.
- [ ] **Per-message compression** — `permessage-deflate` extension (RFC 7692).

## HTTP

- [ ] **HTTP/2 support** — depends on upstream Mongoose C library adding h2.
- [ ] **Streaming responses** — chunked transfer or SSE (Server-Sent Events).
- [ ] **Request body parsing** — built-in JSON / form-data / multipart parsing.

## Routing

- [ ] **Route groups / prefix** — `group!(router, "/api/v1") do ... end` for nested route registration.
- [ ] **Regex constraints** — `route!(router, :get, "/user/:id::r\"\\d{4}\"", ...)`.

## Middleware

- [ ] **Sliding window rate limiter** — token bucket or sliding log algorithm for smoother rate limiting.
- [ ] **Session middleware** — cookie-based session store.
- [ ] **Request body size per-route** — override `max_body` for specific endpoints.

## Performance

- [ ] **Connection pooling** — reuse keep-alive connections more efficiently.
- [ ] **Zero-copy responses** — `Ptr{UInt8}` response bodies to avoid `String` allocation.
- [ ] **Metrics shard count** — auto-tune shard count based on `nthreads()` instead of fixed 8.

## Observability

- [ ] **OpenTelemetry traces** — optional span export for distributed tracing.
- [ ] **Structured error context** — attach request ID, route, and params to error logs.
- [ ] **Metrics labels** — configurable label sets (e.g. route pattern vs literal path).

## Ecosystem

- [ ] **JSON extension** — `ext/MongooseJSONExt.jl` for zero-copy JSON integration.
- [ ] **Documentation site** — Documenter.jl hosted on GitHub Pages with full API reference.
- [ ] **Benchmarks CI** — automated regression benchmarks on PR merge.
