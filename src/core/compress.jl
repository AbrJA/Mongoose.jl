mutable struct Compress <: AbstractMiddleware
    min_size_bytes::Int  # Minimum body size to compress (bytes)
    init_lock::ReentrantLock
    compressors::Vector{Union{Nothing,Compressor}}

    function Compress(min_size_bytes::Int)
        compressors = Vector{Union{Nothing,Compressor}}(nothing, Threads.maxthreadid())
        return new(min_size_bytes, ReentrantLock(), compressors)
    end
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

    ct = ""
    for (k, v) in response.headers
        if k == "Content-Type" || k == "content-type"
            ct = v
            break
        end
    end
    compressible = _is_compressible(ct)

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

    body_data = response.body
    body_size = body_data isa String ? ncodeunits(body_data) : length(body_data)
    body_size < mw.min_size_bytes && return response

    accept_enc = get(request.headers, "accept-encoding", "")
    contains(accept_enc, "gzip") || return response
    (compressible && !already_encoded) || return response

    compressed = _gzip_compress!(_compressor!(mw),
                                 body_data isa String ? Vector{UInt8}(body_data) : body_data)
    compressed === nothing && return response
    length(compressed) >= body_size && return response

    new_headers = mergeheaders(response.headers, ["Content-Encoding" => "gzip"])
    return Response(response.status, new_headers, compressed)
end

# Worst-case gzip size (deflate bound + wrapper) with headroom; trimmed by the
# resize after compression.
@inline _gzip_bound(n::Int)::Int = n + 5 * max(cld(n, 10_000), 1) + 64

# Per-thread compressors (not thread-safe); slots sized by maxthreadid() so
# @spawn on the interactive pool cannot index out of bounds.
@inline function _compressor!(mw::Compress)::Compressor
    tid = Threads.threadid()
    if tid <= length(mw.compressors)
        c = @inbounds mw.compressors[tid]
        c isa Compressor && return c
    end
    return lock(mw.init_lock) do
        while length(mw.compressors) < tid
            push!(mw.compressors, nothing)
        end
        existing = @inbounds mw.compressors[tid]
        existing isa Compressor && return existing
        created = Compressor(UInt8(6))
        @inbounds mw.compressors[tid] = created
        return created
    end
end

# LibDeflate 0.4 resizes the output in place and returns it; 1.x returns the
# number of bytes written.
@inline function _gzip_compress!(compressor::Compressor,
                                 data::Vector{UInt8})::Union{Vector{UInt8},Nothing}
    out = Vector{UInt8}(undef, _gzip_bound(length(data)))
    result = gzip_compress!(compressor, out, data)
    result isa LibDeflateError && return nothing
    compressed = result isa Vector{UInt8} ? result : resize!(out, result)
    # Zero gzip MTIME (bytes 5-8): LibDeflate 0.4 stamps time() there, which
    # would make wire bytes (and wire-byte ETags) nondeterministic.
    if length(compressed) >= 10
        @inbounds begin
            compressed[5] = 0x00
            compressed[6] = 0x00
            compressed[7] = 0x00
            compressed[8] = 0x00
        end
    end
    return compressed
end

@inline function _is_compressible(ct::String)::Bool
    isempty(ct) && return false
    semi = findfirst(';', ct)
    base = semi === nothing ? ct : ct[1:semi-1]
    base = strip(base)
    return base in _COMPRESSIBLE_TYPES
end

"""
    compress(; min_size_bytes=1024) → Compress

Create a GZip compression middleware. Only compresses responses larger than `min_size_bytes` bytes
when the client sends `Accept-Encoding: gzip`.

# Keyword Arguments
- `min_size_bytes::Int`: Minimum response body size to compress (default: `1024` bytes).

# Example
```julia
app = use(app, compress())
app = use(app, compress(min_size_bytes=256))  # More aggressive compression
```
"""
compress(; min_size_bytes::Int=1024) = Compress(min_size_bytes)

Base.show(io::IO, mw::Compress) =
    print(io, "Compress(min_size_bytes=", mw.min_size_bytes, ")")
