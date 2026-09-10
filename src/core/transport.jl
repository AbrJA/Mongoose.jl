"""
    AbstractTransport — replaceable I/O transport.

    The transport is the last FFI boundary: it converts external events into
    `MongooseCore` objects and responses into bytes/frames, and the runtime
    never sees `Ptr{Cvoid}`.

    Today the transport is a **capability-tagged seam** rather than a callable
    interface: implementations declare what they can do via the `supports_*`
    traits, and the server drives the one C implementation
    (`transport/mongoose`). A reference fake (`FakeTransport`, in
    `testing.jl`) drives the whole pipeline with no FFI, which is what
    `TestClient` uses.

    The C transport's concrete lifecycle entry points (used by `start!` /
    `shutdown!`) are `init_server!`, `bind_server!`,
    `spawn_event_loop!`/`stop_event_loop!`, and its send path is
    `send_http_response!`/`send_ws_frame!`/`send_stream_response!` in
    `transport/mongoose`. Extracting a full `init!/listen!/poll!/send!`
    interface behind `AbstractTransport` is tracked as deferred work
    (see WORKLOG, T9): there is a single real implementation today, and the
    trait seam already delivers the replaceability guarantee.

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