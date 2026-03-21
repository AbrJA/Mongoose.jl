"""
    WebSocket message types and handler definitions.
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
    WsEndpoint — Callbacks for a WebSocket endpoint.
"""
struct WsEndpoint
    on_message::Function
    on_open::Union{Function,Nothing}
    on_close::Union{Function,Nothing}
end

function WsEndpoint(; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    return WsEndpoint(on_message, on_open, on_close)
end

"""
    decode_ws_message(msg::MgWsMessage) → WsMessage
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
            return WsBinaryMessage(copy(data))
        end
    else
        return is_text ? WsTextMessage("") : WsBinaryMessage(UInt8[])
    end
end
