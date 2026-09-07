"""
    WebSocket types — loaded early (before Router) since Router references WsEndpoint.
"""

# --- Connection tracking ---

mutable struct WsConn
    const uri::String
    last_active::Float64
    closing::Bool
    WsConn(uri::String, t::Float64=time(), closing::Bool=false) = new(uri, t, closing)
end

# --- Message ---

struct Message
    data::Union{String,Vector{UInt8}}
end

# --- Intent (internal: received WS message + source URI) ---

struct Intent
    body::Message
    uri::String
end

# --- WebSocket endpoint ---

struct WsEndpoint
    on_message::Function
    on_open::Union{Function,Nothing}
    on_close::Union{Function,Nothing}
    allowed_origins::Vector{String}   # empty = allow any Origin
end

function WsEndpoint(; on_message::Function, on_open::Union{Function,Nothing}=nothing,
                    on_close::Union{Function,Nothing}=nothing,
                    allowed_origins::Vector{String}=String[])
    return WsEndpoint(on_message, on_open, on_close, allowed_origins)
end

# --- Internal tagged message wrapper (used by async worker pool) ---

struct Tagged{T}
    id::Int
    payload::T
end
