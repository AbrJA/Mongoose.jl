"""
    String utilities — URL decoding, query parsing, header formatting.
    All functions are allocation-conscious and designed for the hot path.
"""

# --- URL Decoding ---

"""
    urldecode(bytes, start_i, end_i; plus=true) → String

Decode a URL-encoded byte range. Handles `+` → space (form semantics) and
`%XX` hex escapes. Pass `plus=false` for path segments, where `+` is a
literal character (RFC 3986 §2.3).
"""
function urldecode(bytes::AbstractVector{<:UInt8}, start_i::Int, end_i::Int;
                    plus::Bool=true)
    out = IOBuffer(sizehint=end_i - start_i + 1)
    i = start_i
    @inbounds while i <= end_i
        b = bytes[i]
        if plus && b == UInt8('+')
            write(out, UInt8(' '))
            i += 1
        elseif b == UInt8('%') && i + 2 <= end_i
            c1, c2 = bytes[i+1], bytes[i+2]
            if is_hex(c1) && is_hex(c2)
                write(out, UInt8((hex_val(c1) << 4) | hex_val(c2)))
                i += 3
            else
                write(out, b)
                i += 1
            end
        else
            write(out, b)
            i += 1
        end
    end
    return String(take!(out))
end

@inline is_hex(b::UInt8) = (UInt8('0') <= b <= UInt8('9')) || (UInt8('a') <= b <= UInt8('f')) || (UInt8('A') <= b <= UInt8('F'))
@inline hex_val(b::UInt8) = b <= UInt8('9') ? b - UInt8('0') : (b | 0x20) - UInt8('a') + 0x0a

# --- Query String Parsing ---

"""
    parsequery(query::AbstractString) → Dict{String,String}

Single-pass query string parser. Pre-sized for typical query parameter counts.
"""
function parsequery(query::AbstractString)::Dict{String,String}
    isempty(query) && return Dict{String,String}()
    bytes = codeunits(query)
    len = length(bytes)
    params = Dict{String,String}()
    sizehint!(params, 4)
    i = 1
    @inbounds while i <= len
        amp_idx = findnext(==(UInt8('&')), bytes, i)
        pair_end = isnothing(amp_idx) ? len : amp_idx - 1
        eq_idx = findnext(==(UInt8('=')), bytes, i)

        if isnothing(eq_idx) || eq_idx > pair_end
            k_str = urldecode(bytes, i, pair_end)
            !isempty(k_str) && (params[k_str] = "")
        else
            k_str = urldecode(bytes, i, eq_idx - 1)
            v_str = urldecode(bytes, eq_idx + 1, pair_end)
            !isempty(k_str) && (params[k_str] = v_str)
        end
        isnothing(amp_idx) && break
        i = amp_idx + 1
    end
    return params
end

# --- URI Path Stripping ---

"""
    stripquery(uri) → SubString

Return the URI path without the query string. Zero-allocation (returns a view).
"""
@inline function stripquery(uri::AbstractString)::SubString{String}
    len = ncodeunits(uri)
    @inbounds for i in 1:len
        codeunit(uri, i) == UInt8('?') && return SubString(uri, 1, i - 1)
    end
    return SubString(uri, 1, len)
end

# --- Header Formatting ---

"""
    formatheaders(headers) → String

Serialize headers into Mongoose C library format: `"Key: Value\\r\\n"`.
"""
function formatheaders(headers::Vector{Pair{String,String}})::String
    isempty(headers) && return ""
    io = IOBuffer(sizehint=length(headers) * 40)
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    return String(take!(io))
end

# --- Chunked body decoding (RFC 9112 §7.1) ---

"""
    decode_chunked(data) → String

Decode a `Transfer-Encoding: chunked` request body into its payload bytes.

Grammar (RFC 9112 §7.1): `chunk-size [chunk-ext] CRLF chunk-data CRLF`…
terminated by a zero chunk plus optional trailers, then a final CRLF.

Decoding is best-effort and defensive: malformed framing is returned
verbatim (the caller's own parsing/limits still apply), so a hostile body
can never crash or loop the decoder.
"""
function decode_chunked(data::AbstractString)::String
    bytes = codeunits(data)
    n = length(bytes)
    i = 1
    out = IOBuffer()
    while i <= n
        # chunk-size line: "<hex>[;ext] CRLF" — stop at ';' or CR/LF.
        j = i
        while j <= n && bytes[j] != UInt8(';') && bytes[j] != UInt8('\r') && bytes[j] != UInt8('\n')
            j += 1
        end
        size = tryparse(UInt, String(bytes[i:j-1]); base=16)
        size === nothing && return data
        # skip chunk-ext if present
        while j <= n && bytes[j] != UInt8('\r')
            j += 1
        end
        (j + 1 <= n && bytes[j] == UInt8('\r') && bytes[j+1] == UInt8('\n')) || return data
        j += 2
        if size == 0
            # zero chunk: trailing bytes are the trailer section, ending in a
            # blank line — either way the payload is complete.
            return String(take!(out))
        end
        j + Int(size) <= n || return data
        write(out, view(bytes, j:j+Int(size)-1))
        i = j + Int(size)
        (i + 1 <= n && bytes[i] == UInt8('\r') && bytes[i+1] == UInt8('\n')) || return data
        i += 2
    end
    return String(take!(out))
end

# --- Path-segment decoding (RFC 3986) ---

# Is there a percent-escape anywhere in the span? Cheap pre-check so the hot
# capture path pays nothing when segments are plain.
@inline function _has_pct(bytes::AbstractVector{<:UInt8}, s::Int, e::Int)::Bool
    for i in s:e
        bytes[i] == UInt8('%') && return true
    end
    return false
end

# Decode a path segment span; returns the ORIGINAL string when no escaping is
# present (zero-copy hot path). `+` is never turned into a space in paths.
@inline function decode_path_segment(s::AbstractString, j0::Int, j1::Int)::String
    return decode_path_segment(String(SubString(s, j0, j1)))
end

@inline function decode_path_segment(bytes::AbstractVector{<:UInt8}, s::Int, e::Int)::String
    _has_pct(bytes, s, e) || return String(view(bytes, s:e))
    return urldecode(bytes, s, e; plus=false)
end

@inline decode_path_segment(s::String) = decode_path_segment(codeunits(s), 1, ncodeunits(s))

# --- Byte-level utilities ---

@inline to_lower(b::UInt8) = (UInt8('A') <= b <= UInt8('Z')) ? (b | 0x20) : b

"""
    sanitize_header_value(s) → String

Validate a header value for injection safety. Returns empty string if invalid.
Prevents CRLF injection, control characters, and excessive length.
"""
@inline function sanitize_header_value(s::String)::String
    length(s) > 128 && return ""
    @inbounds for i in 1:ncodeunits(s)
        b = codeunit(s, i)
        (b == 0x0d || b == 0x0a || b < 0x20) && return ""
    end
    return s
end
