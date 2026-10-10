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

# Any of these normalize to `Headers` (see `asheaders`); the plain-vector
# method above stays the zero-copy fast path.
Headers(p::Pair) = asheaders(p)
Headers(kvs::AbstractVector) = asheaders(kvs)
Headers(kvs::Tuple) = asheaders(kvs)

"""
    asheaders(input) → Headers

Normalize accepted header inputs into `Headers`: a `Headers` passes through, a
single `Pair` or a vector/tuple of pairs is converted (string keys/values are
`String`ed; anything else throws `ArgumentError`).
"""
asheaders(h::Headers)::Headers = h
asheaders(::Nothing)::Headers = Headers()
asheaders(kvs::Vector{Pair{String,String}})::Headers = Headers(kvs)
asheaders(p::Pair)::Headers = Headers(Pair{String,String}[_headerpair(p)])

function asheaders(kvs::Union{AbstractVector,Tuple})::Headers
    out = Vector{Pair{String,String}}()
    sizehint!(out, length(kvs))
    for k in kvs
        push!(out, _headerpair(k))
    end
    return Headers(out)
end

_headerpair(p::Pair{<:AbstractString,<:AbstractString}) = String(p.first) => String(p.second)
_headerpair(p) = throw(ArgumentError("headers must be Pairs of strings, got $(typeof(p))"))

@inline Base.:(==)(a::Headers, b::Headers) = a.data == b.data
@inline Base.isempty(h::Headers)   = isempty(h.data)
@inline Base.length(h::Headers)    = length(h.data)
@inline Base.getindex(h::Headers, i::Int) = h.data[i]
@inline Base.getindex(h::Headers, key::String) = get(h, key, nothing)
@inline Base.copy(h::Headers)      = Headers(copy(h.data))
@inline Base.iterate(h::Headers)   = iterate(h.data)
@inline Base.iterate(h::Headers, s) = iterate(h.data, s)

# Ordered lazy views preserving duplicate headers (e.g. Set-Cookie); pairs is uncopied.
@inline Base.keys(h::Headers)   = (kv.first for kv in h.data)
@inline Base.values(h::Headers) = (kv.second for kv in h.data)
@inline Base.pairs(h::Headers)  = h.data

# Mutable helpers (used by middleware and the transport when augmenting
# response headers after construction).
@inline Base.push!(h::Headers, kv::Pair{String,String}) = (push!(h.data, kv); h)
@inline Base.push!(h::Headers, key::AbstractString, value::AbstractString) =
    push!(h, String(key) => String(value))
@inline Base.append!(h::Headers, kvs::AbstractVector{<:Pair{String,String}}) =
    (append!(h.data, kvs); h)

"""
    delete!(headers, key) → Headers

Remove every pair whose name matches `key` case-insensitively.
"""
function Base.delete!(h::Headers, key::AbstractString)
    lkey = lowercase(String(key))
    filter!(p -> lowercase(p.first) != lkey, h.data)
    return h
end

formatheaders(h::Headers)::String = formatheaders(h.data)

function Base.get(h::Headers, key::AbstractString, default)
    @inbounds for i in eachindex(h.data)
        _key_eq(h.data[i].first, key) && return h.data[i].second
    end
    return default
end

function Base.haskey(h::Headers, key::AbstractString)::Bool
    @inbounds for i in eachindex(h.data)
        _key_eq(h.data[i].first, key) && return true
    end
    return false
end

"""
    Request — Full HTTP request with owned data.

    `query` is parsed lazily: the transport stores the raw query string and
    [`parsequery`](@ref) memoizes the parsed `Dict` on first access, so requests
    that never read the query pay only the raw-string copy (nothing at all when
    there is no query). `context` is allocated on first access the same way.

    `services` is the app's DI registry, attached by `process` before dispatch:
    `S` is `Nothing` when the app registers none, otherwise the concrete
    NamedTuple type — so [`service`](@ref)/[`withservices`](@ref) resolve
    statically (no dict allocation, no dynamic lookup).

    `remote_addr` is the transport-provided peer address (the client's IP as a
    string, or `nothing` when the transport does not supply one — e.g. the
    standalone pipeline or `FakeTransport`-constructed requests).
"""
mutable struct Request{S} <: AbstractRequest
    const method::Symbol
    const uri::String
    const path::String                          # URI without query string (pre-stripped)
    query::Union{Nothing,Dict{String,String}}   # parsed lazily via `parsequery`
    const query_raw::String                     # raw query (no '?'), lazy source
    const headers::Headers
    const body::String
    context::Union{Nothing,Dict{Symbol,Any}}
    services::S                                 # DI, attached by `process`
    const remote_addr::Union{Nothing,String}

    # Primary constructor — all fields explicit
    function Request(method::Symbol, uri::String, path::String,
                     query::Union{Nothing,Dict{String,String}}, query_raw::String,
                     headers::Headers, body::String,
                     context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                     services::S=nothing,
                     remote_addr::Union{Nothing,String}=nothing) where {S<:Union{Nothing,NamedTuple}}
        return new{S}(method, uri, path, query, query_raw, headers, body, context, services, remote_addr)
    end
end

# Rebuild with the concrete registry; the empty case keeps `Request{Nothing}`.
@inline _attach_services(req::Request{Nothing}, ::NamedTuple{(),Tuple{}}) = req
@inline _attach_services(req::Request, services::NamedTuple) =
    Request(req.method, req.uri, req.path, req.query, req.query_raw,
            req.headers, req.body, req.context, services, req.remote_addr)

# Convenience: pre-parsed query (tests, FakeTransport); no raw source needed.
function Request(method::Symbol, uri::String, path::String,
                 query::Union{Nothing,Dict{String,String}}, headers::Headers,
                 body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                 remote_addr::Union{Nothing,String}=nothing)
    return Request(method, uri, path, query, "", headers, body, context, nothing, remote_addr)
end

# Convenience overload: accept raw pair vectors/tuples and normalize
function Request(method::Symbol, uri::String, path::String,
                 query::Union{Nothing,Dict{String,String}}, headers,
                 body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                 remote_addr::Union{Nothing,String}=nothing)
    return Request(method, uri, path, query, asheaders(headers), body, context, remote_addr)
end

# Convenience: auto-strip query from uri
function Request(method::Symbol, uri::String,
                 query::Union{Nothing,Dict{String,String}}, headers,
                 body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                 remote_addr::Union{Nothing,String}=nothing)
    path = String(stripquery(uri))
    return Request(method, uri, path, query, asheaders(headers), body, context, remote_addr)
end

"""
    parsequery(req) → Dict{String,String}

The request's query parameters, parsed from the raw query on first access and
memoized. Prefer [`query`](@ref) for typed lookups; use this when you need the
whole dict. (The string method [`parsequery(str)`](@ref parsequery) is the
underlying parser.)
"""
@inline function parsequery(req::Request)::Dict{String,String}
    q = req.query
    q !== nothing && return q
    parsed = parsequery(req.query_raw)
    req.query = parsed
    return parsed
end

"""
    Request(; method, uri, query=Dict(), headers=Headers(), body="",
              context=nothing, services=nothing, remote_addr=nothing) → Request

Keyword constructor; `path` is derived from `uri`. Prefer this over the
positional forms for readability.
"""
function Request(; method::Symbol, uri::String,
                 query::Dict{String,String}=Dict{String,String}(),
                 headers=Headers(), body::String="",
                 context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                 services::S=nothing,
                 remote_addr::Union{Nothing,String}=nothing) where {S<:Union{Nothing,NamedTuple}}
    path = String(stripquery(uri))
    return Request(method, uri, path, query, "", asheaders(headers), body, context, services, remote_addr)
end

function Base.show(io::IO, req::Request)
    n = length(req.headers)
    print(io, "Request(", uppercase(string(req.method)), " ", req.uri,
          ", ", n, n == 1 ? " header" : " headers")
    sizeof(req.body) > 0 && print(io, ", ", sizeof(req.body), "-byte body")
    print(io, ")")
end

"""
    context(req) → Dict{Symbol,Any}

Return the request's per-request context dict, creating it lazily on first access.

# Example
```julia
get!(app, "/") do req
    ctx = context(req)
    ctx[:user_id] = 42
    json(Dict("ok" => true))
end
```
"""
@inline function context(req::Request)
    req.context === nothing && (req.context = Dict{Symbol,Any}())
    return req.context::Dict{Symbol,Any}
end

"""
    parseform(req) → Dict{String,String}

Parse an `application/x-www-form-urlencoded` request body.
"""
function parseform(req::Request)::Dict{String,String}
    ct = get(req.headers, "content-type", "")
    startswith(ct, "application/x-www-form-urlencoded") ||
        throw(UnsupportedMediaTypeError("parseform() requires Content-Type: application/x-www-form-urlencoded, got \"$ct\""))
    return parsequery(req.body)
end

"""
    header(req, name) → Union{String,Nothing}

Look up a request header by name (case-insensitive).
"""
@inline header(req::Request, name::AbstractString) = get(req.headers, name, nothing)

# ── Query parameter helpers ──────────────────────────────────────────────────

"""
    query(req, key) → Union{String, Nothing}
    query(req, key, default) → String
    query(req, key, default::T) → T  (auto-parses to type of default)

Type-safe query parameter access with optional default and auto-parsing.

# Examples
```julia
q = query(req, "q", "")           # String with default
page = query(req, "page", 1)      # Auto-parse to Int
limit = query(req, "limit", 20)   # Auto-parse to Int
flag = query(req, "debug", false) # Auto-parse to Bool
```
"""
@inline function query(req::Request, key::String)::Union{String,Nothing}
    return get(parsequery(req), key, nothing)
end

@inline function query(req::Request, key::String, default::String)::String
    return get(parsequery(req), key, default)
end

@inline function query(req::Request, key::String, default::T)::T where {T<:Integer}
    val = get(parsequery(req), key, nothing)
    val === nothing && return default
    parsed = tryparse(T, val)
    return parsed === nothing ? default : parsed
end

@inline function query(req::Request, key::String, default::T)::T where {T<:AbstractFloat}
    val = get(parsequery(req), key, nothing)
    val === nothing && return default
    parsed = tryparse(T, val)
    return parsed === nothing ? default : parsed
end

@inline function query(req::Request, key::String, default::Bool)::Bool
    val = get(parsequery(req), key, nothing)
    val === nothing && return default
    lv = lowercase(val)
    return lv == "true" || lv == "1" || lv == "yes"
end

# ── Body parsing helpers ─────────────────────────────────────────────────────

"""
    body(req) → String

Return the raw request body.
"""
@inline body(req::Request)::String = req.body

# ── Multipart form data parsing ──────────────────────────────────────────────

"""
    MultipartFile — Represents a file uploaded via multipart/form-data.
"""
struct MultipartFile
    name::String           # Form field name
    filename::String       # Original filename
    content_type::String   # MIME type
    data::Vector{UInt8}    # File content
end

Base.show(io::IO, f::MultipartFile) =
    print(io, "MultipartFile(filename=", repr(f.filename), ", ", length(f.data), " bytes)")

"""
    parsemultipart(req) → Dict{String, Union{String, MultipartFile}}

Parse a multipart/form-data request body.
Returns a Dict where string fields map to their values and file fields map to MultipartFile objects.

# Example
```julia
post!(app, "/upload") do req
    parts = parsemultipart(req)
    file = parts["avatar"]::MultipartFile
    text("Received \$(file.filename) (\$(length(file.data)) bytes)")
end
```
"""
function parsemultipart(req::Request)::Dict{String,Union{String,MultipartFile}}
    ct = get(req.headers, "content-type", "")
    startswith(ct, "multipart/form-data") ||
        throw(UnsupportedMediaTypeError("parsemultipart() requires Content-Type: multipart/form-data, got \"$ct\""))

    boundary = _extract_boundary(ct)
    isempty(boundary) && throw(BadRequestError("No boundary found in Content-Type header"))

    return _parse_multipart(codeunits(req.body), boundary)
end

function _extract_boundary(ct::String)::String
    idx = findfirst("boundary=", ct)
    idx === nothing && return ""
    # `findfirst` gives byte indices; step on character boundaries so a
    # multibyte Content-Type cannot throw StringIndexError.
    start = nextind(ct, last(idx))
    start > ncodeunits(ct) && return ""
    if ct[start] == '"'
        # Quoted boundary
        s2 = nextind(ct, start)
        end_idx = findnext('"', ct, s2)
        end_idx === nothing && return ""
        return ct[s2:prevind(ct, end_idx)]
    else
        end_idx = findnext(c -> c == ';' || c == ' ', ct, start)
        end_idx === nothing && return ct[start:end]
        return ct[start:prevind(ct, end_idx)]
    end
end

function _parse_multipart(data::AbstractVector{UInt8}, boundary::String)::Dict{String,Union{String,MultipartFile}}
    result = Dict{String,Union{String,MultipartFile}}()
    delimiter = Vector{UInt8}("--$boundary")
    body_str = String(copy(data))

    parts = split(body_str, "--$boundary")
    for part in parts
        part = strip(part)
        (isempty(part) || part == "--") && continue

        # Split headers from body at first double newline
        header_end = findfirst("\r\n\r\n", part)
        header_end === nothing && (header_end = findfirst("\n\n", part))
        header_end === nothing && continue

        headers_str = part[1:prevind(part, first(header_end))]
        body_content = part[nextind(part, last(header_end)):end]

        body_content = rstrip(body_content, ['\r', '\n'])

        # Parse Content-Disposition
        name = _extract_field(headers_str, "name")
        isempty(name) && continue
        filename = _extract_field(headers_str, "filename")
        content_type = _extract_header_value(headers_str, "Content-Type")

        if isempty(filename)
            result[name] = String(body_content)
        else
            result[name] = MultipartFile(name, filename, content_type, Vector{UInt8}(body_content))
        end
    end
    return result
end

# Extract `field="value"` from a part header without compiling a Regex per
# part (this runs for every multipart field/file).
function _extract_field(headers::AbstractString, field::String)::String
    needle = field * "=\""
    i = findfirst(needle, headers)
    i === nothing && return ""
    start = nextind(headers, last(i))
    start > ncodeunits(headers) && return ""
    stop = findnext('"', headers, start)
    stop === nothing && return ""
    return String(headers[start:prevind(headers, stop)])
end

function _extract_header_value(headers::AbstractString, name::String)::String
    for line in eachsplit(headers, r"\r?\n")
        if startswith(lowercase(line), lowercase(name) * ":")
            return strip(String(line[length(name)+2:end]))
        end
    end
    return "application/octet-stream"
end
