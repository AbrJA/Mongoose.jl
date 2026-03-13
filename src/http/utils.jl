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
from_query(::Type{T}, query::AbstractString) where T
    Deserializes a query string to a struct of the specified type.
"""
from_query(::Type{T}, query::AbstractString) where T = from_query(T, parse_params(query))

"""
from_query(::Type{T}, dict::Dict{String,String}) where T
    Deserializes a dictionary of strings to a struct of the specified type.
"""
@generated function from_query(::Type{T}, dict::Dict{String,String}) where T
    fnames = fieldnames(T)
    ftypes = fieldtypes(T)
    exprs = [:(
        let val = get(dict, $(string(fname)), "")
            $(
                if ftype === String
                    :(val)
                elseif ftype === Bool
                    :(lowercase(val) in ("true", "1", "yes"))
                else
                    :(isempty(val) ? zero($ftype) : parse($ftype, val))
                end
            )
        end
    ) for (fname, ftype) in zip(fnames, ftypes)]
    
    return :(T($(exprs...)))
end

"""
to_headers(headers::Dict{String,String})
    Serializes a dictionary of strings to a string of headers.
"""
function to_headers(headers::Dict{String,String})
    io = IOBuffer()
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    return String(take!(io))
end
