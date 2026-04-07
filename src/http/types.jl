"""
    HTTP request/response types and abstract bases.
"""

"""
    Request — Full HTTP request with owned string data.

`context` is lazily allocated — starts as `nothing` and becomes a
`Dict{Symbol,Any}` on first access via `context!`.
"""
mutable struct Request <: AbstractRequest
    const method::Symbol
    const uri::String
    const query::String
    const headers::Vector{Pair{String,String}}
    const body::String
    context::Union{Nothing,Dict{Symbol,Any}}
end

"""
    Tagged{T} — Connection-tagged payload for async queue routing.
"""
struct Tagged{T}
    id::Int
    payload::T
end

"""
    Message — WebSocket message payload (text or binary).
"""
struct Message
    data::Union{String,Vector{UInt8}}
end

"""
    Response — HTTP response.
"""
struct Response
    status::Int
    headers::String
    body::Union{String,Vector{UInt8}}
    # Inner constructor: convert AbstractString (SubString, etc.) to String
    Response(status::Int, headers::AbstractString, body::AbstractString) =
        new(status, String(headers), String(body))
    Response(status::Int, headers::AbstractString, body::Vector{UInt8}) =
        new(status, String(headers), body)
end

"""
    Intent — Internal routing wrapper: WebSocket message + endpoint URI.
"""
struct Intent
    body::Message
    uri::String
end

const Call  = Union{Tagged{Request}, Tagged{Intent}}
const Reply = Union{Tagged{Response}, Tagged{Message}}

abstract type AbstractFormat end
struct Text <: AbstractFormat end
struct Html <: AbstractFormat end
struct Css <: AbstractFormat end
struct Js <: AbstractFormat end
struct Json <: AbstractFormat end
struct Xml <: AbstractFormat end
struct Binary <: AbstractFormat end

function render_body end
render_body(::Type{T}, body) where T<:AbstractFormat = error("render_body not implemented for type $T and body of type $(typeof(body))")
render_body(::Type{T}, body::String) where T<:AbstractFormat = body
render_body(::Type{Binary}, body::Vector{UInt8}) = body

# Mapping: This is the only place you need to update when adding new format types
function content_type end
content_type(::Type{T}) where T<:AbstractFormat = error("Unsupported format type: $T")
content_type(::Type{Html}) = "Content-Type: text/html; charset=utf-8\r\n"
content_type(::Type{Css}) = "Content-Type: text/css; charset=utf-8\r\n"
content_type(::Type{Js}) = "Content-Type: application/javascript; charset=utf-8\r\n"
content_type(::Type{Text}) = "Content-Type: text/plain; charset=utf-8\r\n"
content_type(::Type{Json}) = "Content-Type: application/json; charset=utf-8\r\n"
content_type(::Type{Xml}) = "Content-Type: application/xml; charset=utf-8\r\n"
content_type(::Type{Binary}) = "Content-Type: application/octet-stream\r\n"

function Response(::Type{T}, body; status::Int=200, headers::Vector{Pair{String,String}}=Pair{String,String}[]) where T<:AbstractFormat
    rendered_body = body isa String ? body : render_body(T, body)  # Avoid dispatch trap for String
    content_headers = isempty(headers) ? content_type(T) : content_type(T) * _formatheaders(headers)
    Response(status, content_headers, rendered_body)
end

Response(body; status::Int=200, headers::Vector{Pair{String,String}}=Pair{String,String}[]) = Response(Text, body; status=status, headers=headers)

function Request(message::MgHttpMessage)
    return Request(_method(message), _uri(message), _query(message), _headers(message), _body(message), nothing)
end

# Fast constructor reusing pre-extracted method and uri (avoids re-extracting from C struct)
function Request(message::MgHttpMessage, method::Symbol, uri::String)
    return Request(method, uri, _query(message), _headers(message), _body(message), nothing)
end

"""
    context!(req) → Dict{Symbol,Any}

Return the request context, creating it on first access.
"""
@inline function context!(req::Request)::Dict{Symbol,Any}
    req.context === nothing && (req.context = Dict{Symbol,Any}())
    return req.context::Dict{Symbol,Any}
end

_method(m::MgHttpMessage) = _method2symbol(m.method)
_uri(m::MgHttpMessage) = _tostring(m.uri)
_query(m::MgHttpMessage) = _tostring(m.query)
_body(m::MgHttpMessage) = _tostring(m.body)

function _method2symbol(str::MgStr)
    (str.buf == C_NULL || str.len == 0) && return :unknown
    len = str.len
    ptr = str.buf
    b1 = unsafe_load(ptr, 1)

    if b1 == 0x47  # 'G'
        if len == 3
            unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x54 && return :get
        end
    elseif b1 == 0x50  # 'P'
        if len == 3
            unsafe_load(ptr, 2) == 0x55 && unsafe_load(ptr, 3) == 0x54 && return :put
        elseif len == 4
            unsafe_load(ptr, 2) == 0x4F && unsafe_load(ptr, 3) == 0x53 && unsafe_load(ptr, 4) == 0x54 && return :post
        elseif len == 5
            unsafe_load(ptr, 2) == 0x41 && unsafe_load(ptr, 3) == 0x54 && unsafe_load(ptr, 4) == 0x43 && unsafe_load(ptr, 5) == 0x48 && return :patch
        end
    elseif b1 == 0x44  # 'D'
        if len == 6
            unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x4C && unsafe_load(ptr, 4) == 0x45 && unsafe_load(ptr, 5) == 0x54 && unsafe_load(ptr, 6) == 0x45 && return :delete
        end
    elseif b1 == 0x4F  # 'O'
        if len == 7
            unsafe_load(ptr, 2) == 0x50 && unsafe_load(ptr, 3) == 0x54 && unsafe_load(ptr, 4) == 0x49 && unsafe_load(ptr, 5) == 0x4F && unsafe_load(ptr, 6) == 0x4E && unsafe_load(ptr, 7) == 0x53 && return :options
        end
    elseif b1 == 0x48  # 'H'
        if len == 4
            unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x41 && unsafe_load(ptr, 4) == 0x44 && return :head
        end
    end

    return Symbol(lowercase(_tostring(str)))
end

function _headers(message::MgHttpMessage)
    pairs = Pair{String,String}[]
    sizehint!(pairs, 12)
    for h in message.headers
        # Mongoose C lib zero-fills unused header slots — stop at first empty
        h.name.buf == C_NULL && break
        h.name.len == 0 && break
        if h.val.buf != C_NULL && h.val.len > 0
            name = _tolowerstr(h.name)
            value = _tostring(h.val)
            push!(pairs, name => value)
        end
    end
    return pairs
end

@inline _tolower(b::UInt8) = (UInt8('A') <= b <= UInt8('Z')) ? (b | 0x20) : b

"""
    _tolowerstr(str::MgStr) → String

Convert an MgStr to a lowercase Julia String in a single pass.
Avoids the double allocation of `lowercase(_tostring(str))`.
"""
@inline function _tolowerstr(str::MgStr)::String
    len = Int(str.len)
    buf = Vector{UInt8}(undef, len)
    src = str.buf
    @inbounds for i in 1:len
        buf[i] = _tolower(unsafe_load(src, i))
    end
    return String(buf)
end


