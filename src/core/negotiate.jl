"""
    Content negotiation middleware — handles Accept header parsing and response format selection.

    Allows handlers to return data (Dict, NamedTuple) and have the response format
    automatically selected based on the client's Accept header.
"""

"""
    Negotiate — Content negotiation middleware.

    Parses the `Accept` header and sets `context(req)[:accept]` to the preferred format.
    If a handler returns a non-Response value, wraps it in the negotiated format.
"""
struct Negotiate <: AbstractMiddleware
    supported::Vector{DataType}  # Ordered by server preference
end

const _ACCEPT_MAP = Dict{String,DataType}(
    "application/json" => Json,
    "text/html"        => Html,
    "text/plain"       => Plain,
    "application/xml"  => Xml,
    "text/xml"         => Xml,
    "*/*"              => Json,  # Default fallback
)

function (mw::Negotiate)(request::Request, next::Function)
    accept_header = get(request.headers, "accept", "*/*")
    format = _negotiate_format(accept_header, mw.supported)
    ctx = context(request)
    ctx[:accept] = format
    return next()
end

"""
    negotiate(; formats=[Json, Html, Plain])

Create a content negotiation middleware.

# Example
```julia
use!(app, negotiate())
get!(app, "/data") do req
    data = Dict("key" => "value")
    # Responds as JSON or HTML based on Accept header
    accept = context(req)[:accept]
    accept === Json ? json(data) : text(string(data))
end
```
"""
negotiate(; formats::Vector{DataType}=[Json, Html, Plain]) = Negotiate(formats)

function _negotiate_format(accept::AbstractString, supported::Vector{DataType})::DataType
    # Parse Accept header: "text/*, application/json;q=0.9, */*;q=0.8"
    # Returns the best supported format; q=0 media ranges are excluded.
    best_format = supported[1]  # Server default
    best_quality = -1.0

    for part in eachsplit(accept, ',')
        part = strip(part)
        isempty(part) && continue

        # Split "type/subtype;q=0.9" into media type and quality
        q = _parse_accept_part(part)
        MIME = q[1]; quality = q[2]
        quality <= 0 && continue                                   # explicitly refused
        fmt = _match_accept_format(MIME, supported)

        if fmt !== nothing && fmt in supported && quality > best_quality
            best_quality = quality
            best_format = fmt
        end
    end

    return best_format
end

"""
    _match_accept_format(mime, supported) → Union{Nothing, DataType}

Resolve a media range to a supported format. Handles exact types and
wildcards (`text/*`, `*/*`); wildcards resolve to the first supported
format whose MIME type matches (server-preference order).
"""
function _match_accept_format(mime_part::AbstractString, supported::Vector{DataType})
    if mime_part == "*/*"
        return supported[1]
    end
    fmt = get(_ACCEPT_MAP, String(mime_part), nothing)
    if fmt !== nothing
        return fmt in supported ? fmt : nothing
    end
    if endswith(mime_part, "/*")
        prefix = String(mime_part[1:prevind(mime_part, lastindex(mime_part))])
        for T in supported
            startswith(mime(T), prefix) && return T
        end
    end
    return nothing
end

function _parse_accept_part(part::AbstractString)
    semicol = findfirst(';', part)
    if semicol === nothing
        return (strip(String(part)), 1.0)
    end
    mime = strip(String(part[1:semicol-1]))
    params = part[semicol+1:end]
    quality = 1.0
    for p in eachsplit(params, ';')
        p = strip(p)
        if startswith(p, "q=")
            quality = tryparse(Float64, p[3:end])
            quality === nothing && (quality = 1.0)
        end
    end
    return (mime, quality)
end
