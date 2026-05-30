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

# --- WebSocket endpoint types ---

abstract type AbstractWsEndpoint end

struct WsEndpoint <: AbstractWsEndpoint
    on_message::Function
    on_open::Union{Function,Nothing}
    on_close::Union{Function,Nothing}
end

function WsEndpoint(; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    return WsEndpoint(on_message, on_open, on_close)
end

struct StaticWsEndpoint{M,O,C} <: AbstractWsEndpoint
    on_message::M
    on_open::O
    on_close::C
end

function StaticWsEndpoint(; on_message, on_open=nothing, on_close=nothing)
    return StaticWsEndpoint{typeof(on_message),typeof(on_open),typeof(on_close)}(on_message, on_open, on_close)
end

# --- Tagged payload wrapper ---

struct Tagged{T}
    id::Int
    payload::T
end

const Call = Tagged{Union{Request,Intent}}
const Reply = Tagged{Union{Response,StreamResponse,Message}}
