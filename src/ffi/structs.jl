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

# Offsets used by the transport. Every one of these is **read-only**: the
# framework never writes into a mongoose struct (no public API exists for that
# and a shifted write could corrupt an adjacent field). Each offset is pinned
# to Mongoose 7.21 and validated once per process by the ABI self-check; on a
# mismatch `remote_addr` is disabled and the server logs loudly.

# `rem` (remote address): next(8) + mgr(8) + loc(24) = 40.
const _MG_CONN_REM_OFFSET = 40

# Trailing bitfield word (verified with `offsetof(struct mg_connection, tls) + 8`:
# sizeof = 288, iobuf = 32, data at 240, tls at 272). Read for the ABI check only.
const _MG_CONN_FLAGS_OFFSET = 280

# `send.len` (bytes queued to the socket): fd(8) + id(8) + recv iobuf(32) → 112,
# +8 for the `len` field. Used for stream/WebSocket backpressure.
const _MG_CONN_SEND_LEN_OFFSET = 120

# `recv.buf` / `recv.len` (bytes read but not yet parsed): recv iobuf at 80.
const _MG_CONN_RECV_OFFSET = 80
const _MG_CONN_RECV_LEN_OFFSET = 88

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
