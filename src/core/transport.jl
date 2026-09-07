"""
    AbstractTransport — replaceable I/O transport.

    The transport is the last FFI boundary. It converts external events into
    `MongooseCore` objects and responses into bytes/frames, and the runtime
    never sees `Ptr{Cvoid}`.

    # Contract (full extraction is a later iteration; these are the seams)

    - lifecycle: `init!(transport, app) → transport`, `close!(transport, app)`
    - listen:    `listen!(transport, app, host, port) → url`
    - event loop:`poll!(transport, app, timeout_ms)` — a single driver step
    - sending:   `send_http!(transport, conn, response)`,
                 `send_ws!(transport, conn, frame)`

    The C implementation lives in `transport/mongoose`. A reference fake
    (`FakeTransport`, in `testing.jl`) drives the whole pipeline with no FFI,
    which is what `TestClient` uses.

    # Capability traits

    Optional features are detected via `supports_*` trait functions and never
    assumed by the runtime: `supports_websocket`, `supports_tls`,
    `supports_streaming`. A transport that cannot do WebSocket simply reports
    `false`; HTTP-only apps keep working.
"""
abstract type AbstractTransport end

# --- Capability traits (default: not supported) ---

supports_websocket(::AbstractTransport) = false
supports_tls(::AbstractTransport) = false
supports_streaming(::AbstractTransport) = false

# Router-side capability spelling (the router protocol already has these
# through `has_ws_routes`; the trait names give one uniform vocabulary).
supports_websocket(r::AbstractRouter) = has_ws_routes(r)
