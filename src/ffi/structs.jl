"""
    FFI struct mappings for the Mongoose C library.
    Provides Julia representations of C structs.
"""

const MgConnection = Ptr{Cvoid}

"""
    MgStr — Mirrors the C `struct mg_str { const char *buf; size_t len; }`.
"""
struct MgStr
    buf::Ptr{UInt8}
    len::Csize_t
end

"""
    _tostring(str::MgStr) → String

Allocating conversion from C string to owned Julia String.
"""
@inline function _tostring(str::MgStr)
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
    head::MgStr           # Request line + headers span
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

"""
    MgHttpServeOpts — Mirrors the C `struct mg_http_serve_opts`.

All pointer fields default to `C_NULL` (NULL pointers), which gives the
Mongoose defaults: POSIX filesystem, auto MIME detection, no SSI, no 404 page.
"""
struct MgHttpServeOpts
    root_dir::Ptr{UInt8}       # Web root directory, must be non-NULL for serve_dir
    ssi_pattern::Ptr{UInt8}    # SSI filename pattern, e.g. "*.shtml"
    extra_headers::Ptr{UInt8}  # Extra HTTP headers appended to every response
    mime_types::Ptr{UInt8}     # Extra MIME types: "ext1=type1,ext2=type2,..."
    page404::Ptr{UInt8}        # Path to custom 404 page, or NULL for default
    fs::Ptr{Cvoid}             # Filesystem implementation, NULL → POSIX
end

"""
    MgTlsOpts — Mirrors the C `struct mg_tls_opts` (Mongoose 7.21).

All credential fields are in-memory PEM/DER blobs represented as `MgStr`.
"""
struct MgTlsOpts
    ca::MgStr
    cert::MgStr
    key::MgStr
    name::MgStr
    skip_verification::Cint
end

"""
    MgHttpServeOpts(root_dir) — Construct opts with only root_dir set (all other fields NULL).
"""
function MgHttpServeOpts(root_dir::Cstring)
    return MgHttpServeOpts(
        Ptr{UInt8}(root_dir), C_NULL, C_NULL, C_NULL, C_NULL, C_NULL
    )
end

function MgWsMessage(ev_data::Ptr{Cvoid})
    ev_data == C_NULL && throw(ServerError("ev_data for WS message is NULL"))
    return unsafe_load(Ptr{MgWsMessage}(ev_data))
end
