"""
    WsEndpoint — Callbacks for a WebSocket endpoint.
"""
abstract type AbstractWsEndpoint end

struct WsEndpoint <: AbstractWsEndpoint
    on_message::Function
    on_open::Union{Function,Nothing}
    on_close::Union{Function,Nothing}
end

function WsEndpoint(; on_message::Function, on_open::Union{Function,Nothing}=nothing, on_close::Union{Function,Nothing}=nothing)
    return WsEndpoint(on_message, on_open, on_close)
end

"""
    StaticWsEndpoint — Concrete WebSocket callbacks for trim-safe static routers.
"""
struct StaticWsEndpoint{M,O,C} <: AbstractWsEndpoint
    on_message::M
    on_open::O
    on_close::C
end

function StaticWsEndpoint(; on_message, on_open=nothing, on_close=nothing)
    return StaticWsEndpoint{typeof(on_message),typeof(on_open),typeof(on_close)}(on_message, on_open, on_close)
end

"""
    _parsewsmsg(msg::MgWsMessage) → Message
"""
function _parsewsmsg(msg::MgWsMessage)
    is_text = (msg.flags & 0x0F) == 1
    if msg.data.len > 0 && msg.data.buf != C_NULL
        if is_text
            return Message(unsafe_string(msg.data.buf, msg.data.len))
        else
            data = unsafe_wrap(Vector{UInt8}, msg.data.buf, Int(msg.data.len); own=false)
            return Message(copy(data))
        end
    end
    return is_text ? Message("") : Message(UInt8[])
end
