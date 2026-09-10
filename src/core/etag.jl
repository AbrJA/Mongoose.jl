"""
    Conditional request middleware — ETag generation + RFC 9110 §13 semantics.
"""

@doc """
    Etag — middleware that computes strong ETags and handles conditional requests.

    Adds an `ETag` header to generated buffered responses (deterministic
    FNV-1a over the response body bytes — stable across restarts, no new
    dependencies), and applies RFC 9110 §13 preconditions:

    - `If-None-Match` match → `304 Not Modified` (GET/HEAD) or
      `412 Precondition Failed` (other methods); `"*"` matches any tag.
    - `If-Match` mismatch → `412 Precondition Failed` (strong comparison).
    - `If-None-Match` uses weak comparison (`W/` prefixes are stripped).

    Streaming responses and raw (non-`Response`) handler returns are passed
    through unchanged — they have no serialized body to hash. Register it
    outside transformation middleware (e.g. before `compress`) so the ETag
    validates the representation that is actually sent.
""" Etag

struct Etag <: AbstractMiddleware end

"""
    etag() — add ETag + conditional request middleware (304/412).

    # Example
    ```julia
    use!(app, etag())                    # before compress, after cors
    use!(app, compress(min_size=1024))
    ```
"""
etag() = Etag()

function (mw::Etag)(request::Request, next::Function)
    response = next()
    response isa Response || return response
    (response.status == 204 || response.status == 304) && return response
    isempty(response.body) && return response
    haskey(response.headers, "etag") && return response

    tag = _etag_of(response)
    if_match = get(request.headers, "if-match", nothing)
    if if_match !== nothing && !_etag_cmp(tag, if_match, false)
        return Response(412, Pair{String,String}[], "")
    end

    if 200 <= response.status < 300
        inm = get(request.headers, "if-none-match", nothing)
        if inm !== nothing && _etag_cmp(tag, inm, true)
            return request.method in (:get, :head) ?
                Response(304, Headers(["etag" => tag]), "") :
                Response(412, Pair{String,String}[], "")
        end
    end

    headers = Headers([copy(response.headers.data); "etag" => tag])
    return Response(response.status, headers, response.body)
end

# --- ETag derivation (FNV-1a 64-bit, deterministic across restarts) ---

@inline function _etag_of(response::Response)::String
    bytes = response.body isa Vector{UInt8} ? response.body : codeunits(response.body)
    return string('"', string(_fnv1a(bytes), base=16, pad=16), '"')
end

@inline function _fnv1a(bytes::AbstractVector{UInt8})::UInt64
    h = 0xcbf29ce484222325
    @inbounds for b in bytes
        h = (h ⊻ UInt64(b)) * 0x100000001b3
    end
    return h
end

# --- RFC 9110 §13 matching ---

# Strong (If-Match) vs weak (If-None-Match) comparison; "*" matches any.
# Weak comparison strips the "W/" weak-prefix on both sides.
@inline function _etag_cmp(tag::String, header::String, weak::Bool)::Bool
    if weak
        mine = startswith(tag, "W/") ? SubString(tag, 3) : SubString(tag, 1, ncodeunits(tag))
    else
        mine = tag
    end
    for part in split(header, ',')
        p = strip(part)
        isempty(p) && continue
        p == "*" && return true
        theirs = weak ? (startswith(p, "W/") ? SubString(p, 3) : SubString(p, 1, ncodeunits(p))) : p
        mine == theirs && return true
    end
    return false
end