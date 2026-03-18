"""
    WebSocket message types and handler definitions.
    Uses separate types for text and binary messages for type stability.
"""

"""
    WsTextMessage — A text WebSocket message (opcode 1).
"""
struct WsTextMessage <: AbstractMessage
    data::String
end

"""
    WsBinaryMessage — A binary WebSocket message (opcode 2).
"""
struct WsBinaryMessage <: AbstractMessage
    data::Vector{UInt8}
end

"""
    WsMessage — Union type for all WebSocket message variants.
"""
const WsMessage = Union{WsTextMessage, WsBinaryMessage}

"""
    IdWsMessage — Connection-tagged WebSocket message for async queue routing.
"""
struct IdWsMessage
    id::Int
    payload::WsMessage
    uri::String
end

"""
    WsHandlers — Callbacks for a WebSocket endpoint.
    on_open: called when a new WebSocket connection is established (receives the HTTP upgrade request).
    on_message: called when a WebSocket message is received.
    on_close: called when a WebSocket connection is closed.
"""
struct WsHandlers
    on_open::Function
    on_message::Function
    on_close::Function
    has_on_open::Bool
    has_on_close::Bool
end

function WsHandlers(; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    noop_open(_) = nothing
    noop_close() = nothing
    return WsHandlers(
        on_open === nothing ? noop_open : on_open,
        on_message,
        on_close === nothing ? noop_close : on_close,
        on_open !== nothing,
        on_close !== nothing
    )
end

"""
    decode_ws_message(msg::MgWsMessage) → WsMessage

Decode a C-level WebSocket message into either a `WsTextMessage` or `WsBinaryMessage`.
For binary messages, the data is copied since the C buffer is only valid during the callback.
"""
function decode_ws_message(msg::MgWsMessage)
    opcode = msg.flags & 0x0F
    is_text = opcode == 1

    if msg.data.len > 0 && msg.data.buf != C_NULL
        if is_text
            return WsTextMessage(unsafe_string(msg.data.buf, msg.data.len))
        else
            ptr = msg.data.buf
            data = unsafe_wrap(Array, ptr, msg.data.len)
            return WsBinaryMessage(copy(data))  # Must copy — C buffer invalidated after callback
        end
    else
        return is_text ? WsTextMessage("") : WsBinaryMessage(UInt8[])
    end
end
