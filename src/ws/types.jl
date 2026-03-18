struct WsMessage <: AbstractMessage
    data::Union{String, Vector{UInt8}}
    is_text::Bool
end

# Connection tagged messages for async queues
struct IdWsMessage
    id::Int
    payload::WsMessage
    uri::String
end

# To decode C messages easily
function WsMessage(msg::MgWsMessage)
    # The flag byte: lowest 4 bits are the opcode. 1 = text frame, 2 = binary frame
    opcode = msg.flags & 0x0F
    is_text = opcode == 1

    # Extract the payload
    if msg.data.len > 0 && msg.data.ptr != C_NULL
        if is_text
            data = unsafe_string(pointer(msg.data.ptr), msg.data.len)
        else
            # Cast Ptr{Cchar} to Ptr{UInt8} for standard Julia byte vectors
            ptr = Ptr{UInt8}(pointer(msg.data.ptr))
            data = unsafe_wrap(Array, ptr, msg.data.len)
            data = copy(data) # Must copy since the pointer becomes invalid after callback
        end
    else
        data = is_text ? "" : UInt8[]
    end
    
    return WsMessage(data, is_text)
end

struct WsHandlers
    on_open::Union{Function, Nothing}
    on_message::Function
    on_close::Union{Function, Nothing}
end
