"""
    FFI struct mappings for the Mongoose C library.
    Provides Julia representations of C structs.
"""

const MgConnection = Ptr{Cvoid}

"""
    MgAddr — Mirrors the C `struct mg_addr` (Mongoose 7.21).

```c
struct mg_addr {
  union { uint8_t ip[16]; uint32_t ip4; uint64_t ip6[2]; } addr; // 16 bytes
  uint16_t port;     // TCP or UDP port in network byte order
  uint8_t scope_id;  // IPv6 scope ID
  bool is_ip6;       // True when the address is IPv6
};
```
The address octets lay in memory in network byte order.
"""
struct MgAddr
    ip0::UInt64   # address octets 0-7
    ip1::UInt64   # address octets 8-15
    port::UInt16
    scope_id::UInt8
    is_ip6::UInt8
end

# Offset of `rem` (remote address) inside `struct mg_connection` (Mongoose
# 7.21): next(8) + mgr(8) + loc(24) = 40.
const _MG_CONN_REM_OFFSET = 40

# Offset of the trailing bitfield word in `struct mg_connection` (Mongoose
# 7.21, 64-bit). Verified with `offsetof(struct mg_connection, tls) + 8`:
# sizeof(mg_connection) = 288, iobuf = 32 bytes, data at 240, tls at 272, so
# the bitfield unit starts at 280. `is_draining` is the 13th declared bitfield
# (0-based bit 12).
const _MG_CONN_FLAGS_OFFSET = 280
const _MG_CONN_IS_DRAINING_BIT = UInt32(1) << 12

"""
    mark_draining!(conn) — set `c->is_draining`: flush pending output, then close.

Mongoose sets `is_draining` itself when a *synchronous* handler clears
`is_resp` inside the `MG_EV_HTTP_MSG` callback. Async replies are sent after
that callback returns, so the poll loop never sees the client's
`Connection: close`; without this flag the header is echoed but the socket
stays open. The struct layout is pinned to Mongoose 7.21 (same ABI assumption
as `_MG_CONN_REM_OFFSET`); wire tests cover it.
"""
@inline function mark_draining!(conn::MgConnection)
    p = Ptr{UInt32}(reinterpret(UInt, conn) + _MG_CONN_FLAGS_OFFSET)
    unsafe_store!(p, unsafe_load(p) | _MG_CONN_IS_DRAINING_BIT)
    return nothing
end

"""
    MgStr — Mirrors the C `struct mg_str { const char *buf; size_t len; }`.
"""
struct MgStr
    buf::Ptr{UInt8}
    len::Csize_t
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
