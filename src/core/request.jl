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

@inline Base.:(==)(a::Headers, b::Headers) = a.data == b.data
@inline Base.isempty(h::Headers)   = isempty(h.data)
@inline Base.length(h::Headers)    = length(h.data)
@inline Base.getindex(h::Headers, i::Int) = h.data[i]
@inline Base.getindex(h::Headers, key::String) = get(h, key, nothing)
@inline Base.copy(h::Headers)      = Headers(copy(h.data))
@inline Base.iterate(h::Headers)   = iterate(h.data)
@inline Base.iterate(h::Headers, s) = iterate(h.data, s)

# Mutable helpers (used by middleware and the transport when augmenting
# response headers after construction).
@inline Base.push!(h::Headers, kv::Pair{String,String}) = (push!(h.data, kv); h)
@inline Base.append!(h::Headers, kvs::AbstractVector{<:Pair{String,String}}) =
    (append!(h.data, kvs); h)

format_headers(h::Headers)::String = format_headers(h.data)

function Base.get(h::Headers, key::String, default)
    lkey = is_lowercase_ascii(key) ? key : lowercase(key)
    @inbounds for i in eachindex(h.data)
        k = h.data[i].first
        if is_lowercase_ascii(k)
            k == lkey && return h.data[i].second
        elseif lowercase(k) == lkey
            return h.data[i].second
        end
    end
    return default
end

function Base.haskey(h::Headers, key::String)::Bool
    lkey = is_lowercase_ascii(key) ? key : lowercase(key)
    @inbounds for i in eachindex(h.data)
        k = h.data[i].first
        if is_lowercase_ascii(k)
            k == lkey && return true
        elseif lowercase(k) == lkey
            return true
        end
    end
    return false
end

"""
    Request — Full HTTP request with owned data.

    Fields are `const` (immutable after construction) except `context`,
    which is lazily allocated on first access for per-request state.

    `remote_addr` is the transport-provided peer address (the client's IP as a
    string, or `nothing` when the transport does not supply one — e.g. the
    standalone pipeline or `TestClient`-constructed requests).
"""
mutable struct Request <: AbstractRequest
    const method::Symbol
    const uri::String
    const path::String                          # URI without query string (pre-stripped)
    const query::Dict{String,String}
    const headers::Headers
    const body::String
    context::Union{Nothing,Dict{Symbol,Any}}
    const remote_addr::Union{Nothing,String}

    # Primary constructor — all fields explicit
    function Request(method::Symbol, uri::String, path::String,
                     query::Dict{String,String}, headers::Headers,
                     body::String,
                     context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                     remote_addr::Union{Nothing,String}=nothing)
        return new(method, uri, path, query, headers, body, context, remote_addr)
    end
end

# Convenience overload: accept raw Vector and wrap automatically
function Request(method::Symbol, uri::String, path::String,
                 query::Dict{String,String}, headers::Vector{Pair{String,String}},
                 body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                 remote_addr::Union{Nothing,String}=nothing)
    return Request(method, uri, path, query, Headers(headers), body, context, remote_addr)
end

# Convenience: auto-strip query from uri
function Request(method::Symbol, uri::String,
                 query::Dict{String,String}, headers::Union{Headers,Vector{Pair{String,String}}},
                 body::String, context::Union{Nothing,Dict{Symbol,Any}}=nothing,
                 remote_addr::Union{Nothing,String}=nothing)
    path = String(strip_query(uri))
    h = headers isa Headers ? headers : Headers(headers)
    return Request(method, uri, path, query, h, body, context, remote_addr)
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
    form(req) → Dict{String,String}

Parse an `application/x-www-form-urlencoded` request body.
"""
function form(req::Request)::Dict{String,String}
    ct = get(req.headers, "content-type", "")
    startswith(ct, "application/x-www-form-urlencoded") ||
        throw(ArgumentError("form() requires Content-Type: application/x-www-form-urlencoded, got \"$ct\""))
    return parse_query(req.body)
end

"""
    header(req, name) → Union{String,Nothing}

Look up a request header by name (case-insensitive).
"""
@inline header(req::Request, name::AbstractString) = get(req.headers, lowercase(String(name)), nothing)

@inline function is_lowercase_ascii(s::String)::Bool
    @inbounds for i in 1:ncodeunits(s)
        b = codeunit(s, i)
        (UInt8('A') <= b <= UInt8('Z')) && return false
    end
    return true
end

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
    return get(req.query, key, nothing)
end

@inline function query(req::Request, key::String, default::String)::String
    return get(req.query, key, default)
end

@inline function query(req::Request, key::String, default::T)::T where {T<:Integer}
    val = get(req.query, key, nothing)
    val === nothing && return default
    parsed = tryparse(T, val)
    return parsed === nothing ? default : parsed
end

@inline function query(req::Request, key::String, default::T)::T where {T<:AbstractFloat}
    val = get(req.query, key, nothing)
    val === nothing && return default
    parsed = tryparse(T, val)
    return parsed === nothing ? default : parsed
end

@inline function query(req::Request, key::String, default::Bool)::Bool
    val = get(req.query, key, nothing)
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

"""
    multipart(req) → Dict{String, Union{String, MultipartFile}}

Parse a multipart/form-data request body.
Returns a Dict where string fields map to their values and file fields map to MultipartFile objects.

# Example
```julia
post!(app, "/upload") do req
    parts = multipart(req)
    file = parts["avatar"]::MultipartFile
    text("Received \$(file.filename) (\$(length(file.data)) bytes)")
end
```
"""
function multipart(req::Request)::Dict{String,Union{String,MultipartFile}}
    ct = get(req.headers, "content-type", "")
    startswith(ct, "multipart/form-data") ||
        throw(ArgumentError("multipart() requires Content-Type: multipart/form-data, got \"$ct\""))

    # Extract boundary
    boundary = _extract_boundary(ct)
    isempty(boundary) && throw(ArgumentError("No boundary found in Content-Type header"))

    return _parse_multipart(codeunits(req.body), boundary)
end

function _extract_boundary(ct::String)::String
    idx = findfirst("boundary=", ct)
    idx === nothing && return ""
    start = last(idx) + 1
    if start <= length(ct) && ct[start] == '"'
        # Quoted boundary
        start += 1
        end_idx = findnext('"', ct, start)
        end_idx === nothing && return ""
        return ct[start:end_idx-1]
    else
        end_idx = findnext(c -> c == ';' || c == ' ', ct, start)
        end_idx === nothing && return ct[start:end]
        return ct[start:end_idx-1]
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

        headers_str = part[1:first(header_end)-1]
        body_content = part[last(header_end)+1:end]

        # Remove trailing \r\n from body
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

function _extract_field(headers::AbstractString, field::String)::String
    pattern = Regex("$(field)=\"([^\"]*)\"")
    m = match(pattern, headers)
    return m === nothing ? "" : m.captures[1]
end

function _extract_header_value(headers::AbstractString, name::String)::String
    for line in eachsplit(headers, r"\r?\n")
        if startswith(lowercase(line), lowercase(name) * ":")
            return strip(String(line[length(name)+2:end]))
        end
    end
    return "application/octet-stream"
end
