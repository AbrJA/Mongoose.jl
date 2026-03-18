"""
    HTTP utility functions — URL decoding, query parsing, header serialization,
    and struct deserialization.
"""

"""
    decode_range(bytes, start_i, end_i) → String

Decode a URL-encoded byte range, handling `+` (space) and `%XX` hex escapes.
"""
function decode_range(bytes::AbstractVector{<:UInt8}, start_i::Int, end_i::Int)
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
            hi = c1 <= UInt8('9') ? c1 - UInt8('0') : (c1 | 0x20) - UInt8('a') + 10
            lo = c2 <= UInt8('9') ? c2 - UInt8('0') : (c2 | 0x20) - UInt8('a') + 10
            decoded_byte = (hi << 4) | lo
            write(out, UInt8(decoded_byte))
            i += 3
        else
            write(out, b)
            i += 1
        end
    end
    return String(take!(out))
end

"""
    parse_params(query) → Dict{String,String}

Parse a URL-encoded query string into key-value pairs.
Handles `key=value&key2=value2` format with URL decoding.
"""
function parse_params(query::AbstractString)
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
            k_str, v_str = decode_range(bytes, i, k_end), ""
        else
            k_end, v_start = eq_idx - 1, eq_idx + 1
            v_end = pair_end
            k_str, v_str = decode_range(bytes, i, k_end), decode_range(bytes, v_start, v_end)
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
    parse_into(::Type{T}, query::AbstractString) where T

Deserialize a URL-encoded query string into a struct of type `T`.
Parses the query string first, then maps key-value pairs to struct fields.

# Example
```julia
struct SearchParams
    q::String
    page::Int
    limit::Int
end

params = parse_into(SearchParams, "q=hello&page=1&limit=10")
# SearchParams("hello", 1, 10)
```
"""
parse_into(::Type{T}, query::AbstractString) where T = parse_into(T, parse_params(query))

"""
    parse_into(::Type{T}, dict::Dict{String,String}) where T

Deserialize a dictionary of strings into a struct of type `T`.
Handles `String`, `Bool`, `Union{T, Nothing}` (optional), and numeric types.
Missing keys default to empty string, zero, `false`, or `nothing` as appropriate.
"""
@generated function parse_into(::Type{T}, dict::Dict{String,String}) where T
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
                    # Handle Union{T, Nothing} — return nothing if empty
                    inner = Base.typesplit(ftype, Nothing)
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

"""
    to_headers(headers::Dict{String,String}) → String

Serialize a dictionary of headers into the `"Key: Value\\r\\n"` format
expected by the Mongoose C library's `mg_http_reply`.
"""
function to_headers(headers::Dict{String,String})
    io = IOBuffer()
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    return String(take!(io))
end
