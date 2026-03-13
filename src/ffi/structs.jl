const MgConnection = Ptr{Cvoid} # Pointer to a generic C void type

struct MgStr
    ptr::Cstring # Pointer to the string data
    len::Csize_t # Length of the string
end

to_string(str::MgStr) = (str.ptr == C_NULL || str.len == 0) ? "" : unsafe_string(pointer(str.ptr), str.len)

struct MgHttpHeader
    name::MgStr
    val::MgStr
end

struct MgHttpMessage
    method::MgStr
    uri::MgStr
    query::MgStr
    proto::MgStr
    headers::NTuple{MG_MAX_HTTP_HEADERS,MgHttpHeader} # Array of headers
    body::MgStr
    message::MgStr

    function MgHttpMessage(ev_data::Ptr{Cvoid})
        ev_data == C_NULL && error("ev_data for HTTP message is NULL")
        return unsafe_load(Ptr{MgHttpMessage}(ev_data))
    end
end

struct MgWsMessage
    data::MgStr
    flags::UInt8
end

function MgWsMessage(ev_data::Ptr{Cvoid})
    ev_data == C_NULL && error("ev_data for WS message is NULL")
    return unsafe_load(Ptr{MgWsMessage}(ev_data))
end
