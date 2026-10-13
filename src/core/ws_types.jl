"""
    WebSocket types — loaded early (before Router) since Router references WSEndpoint.
"""

# --- Connection tracking ---

"""
    WSConn — internal per-connection record (one per open WebSocket).

    Owns the per-connection `state` (user data, released with the connection)
    and the handshake `request` (headers, DI services, remote address), so
    callbacks can receive a [`WSClient`](@ref) handle without re-parsing FFI
    data. Guarded by `RunState.ws_lock` for the registry maps; `state` itself
    is shared with handlers.
"""
mutable struct WSConn
    const uri::String
    const request::Request
    const state::Dict{Symbol,Any}
    last_active::Float64
    closing::Bool
    WSConn(uri::String, request::Request, t::Float64=time(), closing::Bool=false) =
        new(uri, request, Dict{Symbol,Any}(), t, closing)
end

# --- Message ---

"""
    Message — one WebSocket frame.

    `data` is either the UTF-8 text of a text frame or the raw bytes of a
    binary frame. WebSocket handlers receive a `Message` plus a
    [`WSClient`](@ref) handle, and may return a `Message` to reply (or
    `nothing` for no reply).
"""
struct Message
    data::Union{String,Vector{UInt8}}
end

# --- WSClient (public per-connection handle) ---

"""
    WSClient{P} — the per-connection context passed to WebSocket callbacks.

    Fields:
    - `id::Int` — stable connection id (unique per server, monotonic).
    - `uri::String` — the path this connection upgraded on.
    - `params::P` — route parameters (`NamedTuple()` today; typed route params
      are on the roadmap).
    - `request::Request` — the handshake request, with DI services attached:
      `service(client.request, Val(:db))`, headers, `remote_addr`.
    - `state::Dict{Symbol,Any}` — per-connection state; create it in `on_open`
      and release it in `on_close` (it dies with the connection).

    ```julia
    ws!(app, "/chat";
        on_open    = (req, client) -> (client.state[:joined] = time(); true),
        on_message = (msg, client) -> Message("echo: \$(msg.data)"),
        on_close   = client -> audit(client.uri, client.state))
    ```

    Messages from one connection may run concurrently (worker pool); guard
    `state` mutations with a lock when that matters.
"""
struct WSClient{P}
    id::Int
    uri::String
    params::P
    request::Request
    state::Dict{Symbol,Any}
end

# --- Intent (internal: received WS message + source connection) ---

struct Intent
    body::Message
    uri::String
    conn::WSConn
end

# --- WebSocket endpoint ---

struct WSEndpoint{M,O,C}
    on_message::M
    on_open::O
    on_close::C
    allowed_origins::Vector{String}   # empty = allow any Origin
end

function WSEndpoint(; on_message::M, on_open::O=nothing,
                    on_close::C=nothing,
                    allowed_origins=nothing) where {M,O,C}
    return WSEndpoint{M,O,C}(on_message, on_open, on_close, asstrings(allowed_origins))
end

# --- Internal tagged message wrapper (used by async worker pool) ---

struct Tagged{T}
    id::Int
    payload::T
end
