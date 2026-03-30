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
    _parsewsmsg(msg::MgWsMessage) → WsResponse
"""
function _parsewsmsg(msg::MgWsMessage)
    is_text = (msg.flags & 0x0F) == 1
    if msg.data.len > 0 && msg.data.buf != C_NULL
        if is_text
            return WsResponse(unsafe_string(msg.data.buf, msg.data.len))
        else
            data = unsafe_wrap(Array, msg.data.buf, msg.data.len)
            return WsResponse(copy(data))
        end
    end
    return is_text ? WsResponse("") : WsResponse(UInt8[])
end
