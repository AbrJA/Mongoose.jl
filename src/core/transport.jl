"""
    AbstractTransport — replaceable I/O transport.

    The transport is the last FFI boundary: it converts external events into
    `Kernel` objects and responses into bytes/frames, and the runtime
    never sees `Ptr{Cvoid}`.

    Today the transport is a **capability-tagged seam** rather than a callable
    interface: implementations declare what they can do via the ability
    traits (`canws`, `cantls`, `canstream`), and the server
    drives the one C implementation
    (`transport/mongoose`). A reference fake (`FakeTransport`, in
    `testing.jl`) drives the whole pipeline with no FFI, which is what
    `FakeTransport` uses.

    The C transport's concrete lifecycle entry points (used by `start!` /
    `shutdown!`) are `init_server!`, `bind_server!`,
    `spawn_event_loop!`/`stop_event_loop!`, and its send path is
    `send_http_response!`/`send_ws_frame!`/`send_stream_response!` in
    `transport/mongoose`. Extracting a full `init!/listen!/poll!/send!`
    interface behind `AbstractTransport` is tracked as deferred work
    (see WORKLOG, T9): there is a single real implementation today, and the
    trait seam already delivers the replaceability guarantee.

    # Capability traits

    Optional features are detected via trait functions and never assumed
    by the runtime: `canws`, `cantls`,
    `canstream`. A transport that cannot do WebSocket simply reports
    `false`; HTTP-only apps keep working.
"""
abstract type AbstractTransport end

# --- Capability traits (default: not supported) ---

"""
    canws(transport) → Bool

Whether the transport supports WebSocket upgrades. Defaults to `false`;
implementations override it for their capability set.
"""
canws(::AbstractTransport) = false

"""
    cantls(transport) → Bool

Whether the transport supports TLS. Defaults to `false`.
"""
cantls(::AbstractTransport) = false

"""
    canstream(transport) → Bool

Whether the transport supports streamed (chunked) responses. Defaults to
`false`.
"""
canstream(::AbstractTransport) = false