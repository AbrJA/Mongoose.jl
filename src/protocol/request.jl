"""
    HTTP Request — transport-agnostic, immutable (except lazy context).

    Constructed from pure Julia types only. The transport adapter layer
    is responsible for converting FFI data into this struct.
"""

"""
    Headers — lightweight wrapper around the parsed header pairs.

    Ownership of the type by Mongoose allows defining `get`/`haskey`
    without committing Base piracy on `Vector{Pair{String,String}}`.
"""
struct Headers
    data::Vector{Pair{String,String}}
    Headers(v::Vector{Pair{String,String}}) = new(v)
    Headers() = new(Pair{String,String}[])
end

@inline Base.isempty(h::Headers)  = isempty(h.data)
@inline Base.length(h::Headers)   = length(h.data)
@inline Base.iterate(h::Headers)  = iterate(h.data)
@inline Base.iterate(h::Headers, s) = iterate(h.data, s)

function Base.get(h::Headers, key::String, default)
    lkey = is_lowercase_ascii(key) ? key : lowercase(key)
    @inbounds for i in eachindex(h.data)
        h.data[i].first == lkey && return h.data[i].second
    end
    return default
end

function Base.haskey(h::Headers, key::String)::Bool
    lkey = is_lowercase_ascii(key) ? key : lowercase(key)
    @inbounds for i in eachindex(h.data)
        h.data[i].first == lkey && return true
    end
    return false
end

"""
    Request — Full HTTP request with owned data.

    Fields are `const` (immutable after construction) except `context`,
    which is lazily allocated on first access for per-request state.
"""
mutable struct Request <: AbstractRequest
    const method::Symbol
    const uri::String
    const path::String                          # URI without query string (pre-stripped)
    const query::Dict{String,String}
    const headers::Headers
    const body::String
    context::Union{Nothing,Dict{Symbol,Any}}

    # Primary constructor — all fields explicit
    function Request(method::Symbol, uri::String, path::String,
                     query::Dict{String,String}, headers::Headers,
                     body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing)
        return new(method, uri, path, query, headers, body, context)
    end
end

# Convenience overload: accept raw Vector and wrap automatically
function Request(method::Symbol, uri::String, path::String,
                 query::Dict{String,String}, headers::Vector{Pair{String,String}},
                 body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing)
    return Request(method, uri, path, query, Headers(headers), body, context)
end

# Convenience: auto-strip query from uri
function Request(method::Symbol, uri::String,
                 query::Dict{String,String}, headers::Union{Headers,Vector{Pair{String,String}}},
                 body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing)
    path = String(strip_query(uri))
    h = headers isa Headers ? headers : Headers(headers)
    return Request(method, uri, path, query, h, body, context)
end

"""
    context!(req) → Dict{Symbol,Any}

Return the request context, creating it on first access.
Thread-safe via atomic compare-and-swap semantics (single writer per request).
"""
@inline function context!(req::Request)
    req.context === nothing && (req.context = Dict{Symbol,Any}())
    return req.context::Dict{Symbol,Any}
end

@inline function is_lowercase_ascii(s::String)::Bool
    @inbounds for i in 1:ncodeunits(s)
        b = codeunit(s, i)
        (UInt8('A') <= b <= UInt8('Z')) && return false
    end
    return true
end
