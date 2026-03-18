"""
    FFI struct mappings for the Mongoose C library.
    Provides Julia representations of C structs and zero-copy string views.
"""

using StringViews

const MgConnection = Ptr{Cvoid}

"""
    MgStr — Mirrors the C `struct mg_str { const char *buf; size_t len; }`.
"""
struct MgStr
    buf::Ptr{UInt8}
    len::Csize_t
end

"""
    to_view(str::MgStr) → StringView

Zero-copy view into the C string buffer. The returned view is only valid
during the current event callback — do NOT store it beyond that scope.
"""
@inline function to_view(str::MgStr)
    (str.buf == C_NULL || str.len == 0) && return StringView(UInt8[])
    buf = unsafe_wrap(Vector{UInt8}, str.buf, str.len; own=false)
    return StringView(buf)
end

"""
    to_string(str::MgStr) → String

Allocating conversion from C string to owned Julia String.
Use `to_view` when you only need temporary read access.
"""
@inline function to_string(str::MgStr)
    (str.buf == C_NULL || str.len == 0) && return ""
    return unsafe_string(str.buf, str.len)
end

"""
    MgHttpHeader — Mirrors the C `struct mg_http_header`.
"""
struct MgHttpHeader
    name::MgStr
    val::MgStr
end

"""
    MgHttpMessage — Mirrors the C `struct mg_http_message`.
    Constructed from `ev_data` pointer during HTTP events.
"""
struct MgHttpMessage
    method::MgStr
    uri::MgStr
    query::MgStr
    proto::MgStr
    headers::NTuple{MG_MAX_HTTP_HEADERS,MgHttpHeader}
    body::MgStr
    message::MgStr

    function MgHttpMessage(ev_data::Ptr{Cvoid})
        ev_data == C_NULL && throw(ServerError("ev_data for HTTP message is NULL"))
        return unsafe_load(Ptr{MgHttpMessage}(ev_data))
    end
end

"""
    MgWsMessage — Mirrors the C `struct mg_ws_message`.
    Contains WebSocket frame data and flags.
"""
struct MgWsMessage
    data::MgStr
    flags::UInt8
end

function MgWsMessage(ev_data::Ptr{Cvoid})
    ev_data == C_NULL && throw(ServerError("ev_data for WS message is NULL"))
    return unsafe_load(Ptr{MgWsMessage}(ev_data))
end
