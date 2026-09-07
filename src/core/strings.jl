"""
    String utilities — URL decoding, query parsing, header formatting.
    All functions are allocation-conscious and designed for the hot path.
"""

# --- URL Decoding ---

"""
    url_decode(bytes, start_i, end_i) → String

Decode a URL-encoded byte range. Handles `+` → space and `%XX` hex escapes.
"""
function url_decode(bytes::AbstractVector{<:UInt8}, start_i::Int, end_i::Int)
    out = IOBuffer(sizehint=end_i - start_i + 1)
    i = start_i
    @inbounds while i <= end_i
        b = bytes[i]
        if b == UInt8('+')
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
    parse_query(query::AbstractString) → Dict{String,String}

Single-pass query string parser. Pre-sized for typical query parameter counts.
"""
function parse_query(query::AbstractString)::Dict{String,String}
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
            k_str = url_decode(bytes, i, pair_end)
            !isempty(k_str) && (params[k_str] = "")
        else
            k_str = url_decode(bytes, i, eq_idx - 1)
            v_str = url_decode(bytes, eq_idx + 1, pair_end)
            !isempty(k_str) && (params[k_str] = v_str)
        end
        isnothing(amp_idx) && break
        i = amp_idx + 1
    end
    return params
end

# --- URI Path Stripping ---

"""
    strip_query(uri) → SubString

Return the URI path without the query string. Zero-allocation (returns a view).
"""
@inline function strip_query(uri::AbstractString)::SubString{String}
    len = ncodeunits(uri)
    @inbounds for i in 1:len
        codeunit(uri, i) == UInt8('?') && return SubString(uri, 1, i - 1)
    end
    return SubString(uri, 1, len)
end

# --- Header Formatting ---

"""
    format_headers(headers) → String

Serialize headers into Mongoose C library format: `"Key: Value\\r\\n"`.
"""
function format_headers(headers::Vector{Pair{String,String}})::String
    isempty(headers) && return ""
    io = IOBuffer(sizehint=length(headers) * 40)
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    return String(take!(io))
end

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
