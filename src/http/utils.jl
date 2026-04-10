"""
    HTTP utility functions — URL decoding, query parsing, header serialization,
    and struct deserialization.
"""

"""
    _urldecode(bytes, start_i, end_i) → String

Decode a URL-encoded byte range, handling `+` (space) and `%XX` hex escapes.
"""
function _urldecode(bytes::AbstractVector{<:UInt8}, start_i::Int, end_i::Int)
    out = IOBuffer()
    i = start_i
    while i <= end_i
        b = bytes[i]
        if b == UInt8('+')
            write(out, UInt8(' '))
            i += 1
        elseif b == UInt8('%') && i + 2 <= end_i
            c1 = bytes[i+1]
            c2 = bytes[i+2]
            if _ishex(c1) && _ishex(c2)
                hi = c1 <= UInt8('9') ? c1 - UInt8('0') : (c1 | 0x20) - UInt8('a') + 10
                lo = c2 <= UInt8('9') ? c2 - UInt8('0') : (c2 | 0x20) - UInt8('a') + 10
                decoded_byte = (hi << 4) | lo
                write(out, UInt8(decoded_byte))
                i += 3
            else
                # Invalid hex escape — emit '%' literally
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

@inline function _ishex(b::UInt8)
    return (UInt8('0') <= b <= UInt8('9')) || (UInt8('a') <= b <= UInt8('f')) || (UInt8('A') <= b <= UInt8('F'))
end

function _query2dict(query)
    bytes = codeunits(query)
    len = length(bytes)
    params = Dict{String,String}()
    sizehint!(params, 4)
    i = 1
    while i <= len
        amp_idx = findnext(==(UInt8('&')), bytes, i)
        pair_end = isnothing(amp_idx) ? len : amp_idx - 1
        eq_idx = findnext(==(UInt8('=')), bytes, i)

        local k_str::String
        local v_str::String

        if isnothing(eq_idx) || eq_idx > pair_end
            k_end, v_start = pair_end, pair_end + 1
            k_str, v_str = _urldecode(bytes, i, k_end), ""
        else
            k_end, v_start = eq_idx - 1, eq_idx + 1
            v_end = pair_end
            k_str, v_str = _urldecode(bytes, i, k_end), _urldecode(bytes, v_start, v_end)
        end
        if !isempty(k_str)
            params[k_str] = v_str
        end
        i = pair_end + 2

        if isnothing(amp_idx)
            break
        end
    end
    return params
end

"""
    _dict2struct(::Type{T}, dict::Dict{String,String}) where T

Deserialize a dictionary of strings into a struct of type `T`.
Handles `String`, `Bool`, `Union{T, Nothing}` (optional), and numeric types.
Missing keys default to empty string, zero, `false`, or `nothing` as appropriate.
"""
@generated function _dict2struct(::Type{T}, dict::Dict{String,String}) where T
    fnames = fieldnames(T)
    ftypes = fieldtypes(T)
    exprs = [:(
        let val = get(dict, $(string(fname)), "")
            $(
                if ftype === String
                    :(val)
                elseif ftype === Bool
                    :(lowercase(val) in ("true", "1", "yes"))
                elseif ftype isa Union && Nothing <: ftype
                    # Handle Union{T, Nothing} — return nothing if empty.
                    # Extract the non-Nothing type without relying on the
                    # undocumented Base.typesplit internal.
                    inner = only(t for t in Base.uniontypes(ftype) if t !== Nothing)
                    if inner === String
                        :(isempty(val) ? nothing : val)
                    else
                        :(isempty(val) ? nothing : parse($inner, val))
                    end
                else
                    :(isempty(val) ? zero($ftype) : parse($ftype, val))
                end
            )
        end
    ) for (fname, ftype) in zip(fnames, ftypes)]

    return :(T($(exprs...)))
end

query(::Type{T}, req::AbstractRequest) where T = query(T, req.query)
query(::Type{T}, str::String) where T = _dict2struct(T, _query2dict(str))

"""
    _formatheaders(headers::Vector{Pair{String,String}}) → String

Serialize headers into the `"Key: Value\\r\\n"` format
expected by the Mongoose C library's `mg_http_reply`.
"""
function _formatheaders(headers::Vector{Pair{String,String}})
    isempty(headers) && return ""
    # Estimate ~40 bytes per header (key: value\r\n)
    io = IOBuffer(sizehint=length(headers) * 40)
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    return String(take!(io))
end

function Base.get(headers::Vector{Pair{String,String}}, key::String, default)
    # Fast path: if key is already all-lowercase ASCII, compare directly without allocating.
    # Stored header names are always lowercase (normalised in _headers()).
    lkey = _islowerascii(key) ? key : lowercase(key)
    @inbounds for i in eachindex(headers)
        headers[i].first == lkey && return headers[i].second
    end
    return default
end

"""
    _islowerascii(s) → Bool

Return `true` when `s` contains no uppercase ASCII letters (A–Z).
"""
@inline function _islowerascii(s::String)::Bool
    @inbounds for i in 1:ncodeunits(s)
        b = codeunit(s, i)
        (UInt8('A') <= b <= UInt8('Z')) && return false
    end
    return true
end
