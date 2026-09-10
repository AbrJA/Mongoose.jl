"""
    Transport adapter — converts Mongoose C FFI types into pure-Julia Request objects.

    This is the ONLY place where FFI structs cross into the application layer.
    Everything above this layer works with pure Julia types exclusively.
"""

"""
    adapt_request(msg::MgHttpMessage) → Request

Convert a Mongoose C HTTP message into a transport-agnostic Request.
This is the single point of FFI→Julia boundary crossing for requests.
"""
function adapt_request(msg::MgHttpMessage;
                       remote_addr::Union{Nothing,String}=nothing)::Request
    method = parse_method(msg.method)
    uri = to_string(msg.uri)
    query_str = to_string(msg.query)
    query = parse_query(query_str)
    headers = parse_headers(msg)
    body = body_of(msg, headers)
    path = strip_query(uri)
    return Request(method, uri, String(path), query, headers, body, nothing, remote_addr)
end

"""
    adapt_request(msg::MgHttpMessage, method::Symbol, uri::String; remote_addr=nothing) → Request

Fast-path adapter reusing pre-extracted method and URI (avoids redundant C→Julia conversion).
"""
function adapt_request(msg::MgHttpMessage, method::Symbol, uri::String;
                       remote_addr::Union{Nothing,String}=nothing)::Request
    query_str = to_string(msg.query)
    query = parse_query(query_str)
    headers = parse_headers(msg)
    body = body_of(msg, headers)
    path = String(strip_query(uri))
    return Request(method, uri, path, query, headers, body, nothing, remote_addr)
end

# --- Request body extraction ---

# RFC 9112 §7.1: the C layer folds complete bodies into msg.body but leaves
# `Transfer-Encoding: chunked` bodies un-decoded — decode them here so
# `body(req)`/`form`/`multipart` see real payload bytes.
@inline function body_of(msg::MgHttpMessage, headers::Headers)::String
    raw = to_string(msg.body)
    te = get(headers, "transfer-encoding", "")
    return occursin("chunked", te) ? decode_chunked(raw) : raw
end

"""
    adapt_request_minimal(msg::MgHttpMessage) → Request

Minimal adapter for WebSocket upgrade — only method, URI, query, and headers.
Skips body parsing (WebSocket upgrade requests have no meaningful body).
"""
function adapt_request_minimal(msg::MgHttpMessage)::Request
    method = parse_method(msg.method)
    uri = to_string(msg.uri)
    query_str = to_string(msg.query)
    query = parse_query(query_str)
    headers = parse_headers(msg)
    path = String(strip_query(uri))
    return Request(method, uri, path, query, headers, "", nothing, nothing)
end

# --- Remote address (peer IP for per-client rate limiting, logs, …) ---

"""
    remote_addr_of(conn::MgConnection) → Union{Nothing,String}

Resolve the peer's bare IP (host only, port stripped) by reading `rem` from the
C `mg_connection` (Mongoose 7.21: `rem` at offset 40). Returns `nothing` when no
address could be read. The port is deliberately excluded so rate-limit buckets
key on the client host, not on the ephemeral TCP port each connection binds.
"""
@inline function remote_addr_of(conn::MgConnection)::Union{Nothing,String}
    conn == C_NULL && return nothing
    ptr = Ptr{MgAddr}(reinterpret(UInt, conn) + _MG_CONN_REM_OFFSET)
    rem = unsafe_load(ptr)
    return rem.is_ip6 != 0 ? _fmt_ip6(rem) : _fmt_ip4(rem.ip0)
end

# IPv4: octets 0-3 of the union in network byte order; a little-endian 64-bit
# load puts octet 1 in the least-significant byte.
@inline function _fmt_ip4(v::UInt64)::String
    return string(v & 0xff, ".",
                  (v >> 8) & 0xff, ".",
                  (v >> 16) & 0xff, ".",
                  (v >> 24) & 0xff)
end

# IPv6: full expanded form ("abcd:ef01:…:1234"), no :: compression — stable
# and unambiguous as a bucket key.
@inline function _fmt_ip6(rem::MgAddr)::String
    v0 = bswap(rem.ip0)
    v1 = bswap(rem.ip1)
    groups = ntuple(i -> (v0 >> (16 * (4 - i))) & 0xffff, 4)
    groups2 = ntuple(i -> (v1 >> (16 * (4 - i))) & 0xffff, 4)
    return join((string(g, base=16, pad=4) for g in (groups..., groups2...)), ":")
end

# --- Internal conversion helpers ---

@inline function to_string(str::MgStr)::String
    (str.buf == C_NULL || str.len == 0) && return ""
    return unsafe_string(str.buf, str.len)
end

"""
    parse_method(str::MgStr) → Symbol

Convert the C method string to a lowercase `Symbol`. The previous hand-rolled
byte comparison avoided a per-request `String` at the cost of ~25 hard-to-read
lines; the surrounding adapter already allocates Strings/Dicts per request, so
the simple version is the right trade-off.
"""
@inline function parse_method(str::MgStr)::Symbol
    s = to_string(str)
    isempty(s) && return :unknown
    return Symbol(lowercase(s))
end

"""
    parse_headers(msg::MgHttpMessage) → Headers

Extract and normalize headers from C struct. Names are lowercased in a single pass.
"""
function parse_headers(msg::MgHttpMessage)::Headers
    pairs = Pair{String,String}[]
    sizehint!(pairs, 12)
    for h in msg.headers
        h.name.buf == C_NULL && break
        h.name.len == 0 && break
        if h.val.buf != C_NULL && h.val.len > 0
            name = lowercase_string(h.name)
            value = to_string(h.val)
            push!(pairs, name => value)
        end
    end
    return Headers(pairs)
end

"""
    lowercase_string(str::MgStr) → String

Single-pass lowercase + string allocation from C data. Avoids double allocation
of `lowercase(unsafe_string(...))`.
"""
@inline function lowercase_string(str::MgStr)::String
    len = Int(str.len)
    buf = Vector{UInt8}(undef, len)
    src = str.buf
    @inbounds for i in 1:len
        buf[i] = to_lower(unsafe_load(src, i))
    end
    return String(buf)
end
