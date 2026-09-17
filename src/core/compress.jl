struct Compress <: AbstractMiddleware
    min_size::Int  # Minimum body size to compress (bytes)
end

@doc """
    Compress — GZip compression middleware.

    Compresses response bodies when the client supports it
    (Accept-Encoding: gzip). Skips already-compressed, streaming, or small
    responses.
""" Compress

const _COMPRESSIBLE_TYPES = Set([
    "text/plain", "text/html", "text/css", "text/xml",
    "application/json", "application/javascript", "application/xml",
    "application/xhtml+xml", "image/svg+xml"
])

function (mw::Compress)(request::Request, next::Function)
    response = next()
    response isa Response || return response

    # Check if response is compressible content type
    ct = ""
    for (k, v) in response.headers
        if k == "Content-Type" || k == "content-type"
            ct = v
            break
        end
    end
    compressible = _is_compressible(ct)

    # Already encoded?
    already_encoded = any(h -> h.first == "Content-Encoding" || h.first == "content-encoding",
                          response.headers)

    # Cache-correctness: whenever the body could have been compressed, advertise
    # that the representation varies with Accept-Encoding.
    if compressible && !already_encoded
        has_vary = any(h -> h.first == "Vary" || h.first == "vary", response.headers)
        if !has_vary
            response = mergeheaders(response, ["Vary" => "Accept-Encoding"])
        end
    end

    # Skip small responses
    body_data = response.body
    body_size = body_data isa String ? ncodeunits(body_data) : length(body_data)
    body_size < mw.min_size && return response

    # Check if client accepts gzip
    accept_enc = get(request.headers, "accept-encoding", "")
    contains(accept_enc, "gzip") || return response
    (compressible && !already_encoded) || return response

    # Compress
    compressed = transcode(GzipCompressor, body_data isa String ? Vector{UInt8}(body_data) : body_data)

    # Only use compressed if it's actually smaller
    length(compressed) >= body_size && return response

    new_headers = mergeheaders(response.headers, ["Content-Encoding" => "gzip"])
    return Response(response.status, new_headers, compressed)
end

@inline function _is_compressible(ct::String)::Bool
    isempty(ct) && return false
    # Check base type without parameters
    semi = findfirst(';', ct)
    base = semi === nothing ? ct : ct[1:semi-1]
    base = strip(base)
    return base in _COMPRESSIBLE_TYPES
end

"""
    compress(; min_size=1024) → Compress

Create a GZip compression middleware. Only compresses responses larger than `min_size` bytes
when the client sends `Accept-Encoding: gzip`.

# Keyword Arguments
- `min_size::Int`: Minimum response body size to compress (default: `1024` bytes).

# Example
```julia
use!(app, compress())
use!(app, compress(min_size=256))  # More aggressive compression
```
"""
compress(; min_size::Int=1024) = Compress(min_size)
