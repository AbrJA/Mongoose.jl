"""
    WebSocket types — loaded early (before Router) since Router references WSEndpoint.
"""

# --- Connection tracking ---

mutable struct WSConn
    const uri::String
    last_active::Float64
    closing::Bool
    WSConn(uri::String, t::Float64=time(), closing::Bool=false) = new(uri, t, closing)
end

# --- Message ---

"""
    Message — one WebSocket frame.

    `data` is either the UTF-8 text of a text frame or the raw bytes of a
    binary frame. WebSocket handlers receive a `Message` and may return a
    `Message` to reply (or `nothing` for no reply).
"""
struct Message
    data::Union{String,Vector{UInt8}}
end

# --- Intent (internal: received WS message + source URI) ---

struct Intent
    body::Message
    uri::String
end

# --- WebSocket endpoint ---

struct WSEndpoint
    on_message::Function
    on_open::Union{Function,Nothing}
    on_close::Union{Function,Nothing}
    allowed_origins::Vector{String}   # empty = allow any Origin
end

function WSEndpoint(; on_message::Function, on_open::Union{Function,Nothing}=nothing,
                    on_close::Union{Function,Nothing}=nothing,
                    allowed_origins=nothing)
    return WSEndpoint(on_message, on_open, on_close, asstrings(allowed_origins))
end

# --- Internal tagged message wrapper (used by async worker pool) ---

struct Tagged{T}
    id::Int
    payload::T
end
