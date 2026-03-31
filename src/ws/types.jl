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
    _parsewsmsg(msg::MgWsMessage) → Message
"""
function _parsewsmsg(msg::MgWsMessage)::Message
    is_text = (msg.flags & 0x0F) == 1
    if msg.data.len > 0 && msg.data.buf != C_NULL
        if is_text
            return Message(unsafe_string(msg.data.buf, msg.data.len))
        else
            data = unsafe_wrap(Array, msg.data.buf, msg.data.len)
            return Message(copy(data))
        end
    end
    return is_text ? Message("") : Message(UInt8[])
end
