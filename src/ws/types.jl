"""
    WebSocket message types and handler definitions.
"""

struct WsMessage{Format,T}
    data::T
end

WsMessage(::Type{Format}, data::T) where {Format,T} = WsMessage{Format,T}(data)

const WsTextMessage = WsMessage{Text,String}
const WsBinaryMessage = WsMessage{Binary,Vector{UInt8}}

"""
    WsRouted — WebSocket message bundled with its endpoint URI for routing.
"""
struct WsRouted
    message::WsMessage
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
    is_text = (msg.flags & 0x0F) == 1

    if msg.data.len > 0 && msg.data.buf != C_NULL
        if is_text
            return WsMessage(Text, unsafe_string(msg.data.buf, msg.data.len))
        else
            data = unsafe_wrap(Array, msg.data.buf, msg.data.len)
            return WsMessage(Binary, copy(data))
        end
    end
    return is_text ? WsMessage(Text, "") : WsMessage(Binary, UInt8[])
end
