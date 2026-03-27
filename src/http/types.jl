"""
    HTTP request/response types and abstract bases.
"""

"""
    Request — Full HTTP request with owned string data.
"""
struct Request <: AbstractRequest
    method::Symbol
    uri::String
    query::String
    headers::Vector{Pair{String,String}}
    body::String
    context::Dict{Symbol,Any}
end

"""
    LazyRequest — Lightweight HTTP request with lazy header access.
"""
struct LazyRequest <: AbstractRequest
    method::Symbol
    uri::String
    message::MgHttpMessage
    context::Dict{Symbol,Any}
end

"""
    RawResponse — Pre-formatted raw bytes.
"""
struct RawResponse <: AbstractResponse
    bytes::Vector{UInt8}
end

# Maybe add factory here

"""
    Tagged{T} — Connection-tagged payload for async queue routing.
"""
struct Tagged{T}
    id::Int
    payload::T
end

"""
    Response — HTTP response.
"""
struct Response <: AbstractResponse
    status::Int
    headers::String
    body::String
end

abstract type AbstractFormat end
struct Text <: AbstractFormat end
struct Html <: AbstractFormat end
struct Css <: AbstractFormat end
struct Js <: AbstractFormat end
struct Json <: AbstractFormat end
struct Xml <: AbstractFormat end

render_body(::Type{T}, body) where T<:AbstractFormat = error("render_body not implemented for type $T and body of type $(typeof(body))")
render_body(::Type{T}, body::String) where T<:AbstractFormat = body

# Mapping: This is the only place you need to update when adding new types
content_type(::Type{T}) where T<:AbstractFormat = error("Unsupported format type: $T")
content_type(::Type{Html}) = "Content-Type: text/html; charset=utf-8\r\n"
content_type(::Type{Css}) = "Content-Type: text/css; charset=utf-8\r\n"
content_type(::Type{Js}) = "Content-Type: application/javascript; charset=utf-8\r\n"
content_type(::Type{Text}) = "Content-Type: text/plain; charset=utf-8\r\n"
content_type(::Type{Json}) = "Content-Type: application/json; charset=utf-8\r\n"
content_type(::Type{Xml}) = "Content-Type: application/xml; charset=utf-8\r\n"

function Response(::Type{T}, body; status::Int=200, headers::Vector{Pair{String,String}}=Pair{String,String}[]) where T<:AbstractFormat
    h = content_type(T) * (isempty(headers) ? "" : _formatheaders(headers))
    Response(status, h, render_body(T, body))
end

Response(body; status::Int=200, headers::Vector{Pair{String,String}}=Pair{String,String}[]) = Response(Text, body; status=status, headers=headers)

function Request(message::MgHttpMessage)
    return Request(_method(message), _uri(message), _query(message), _headers(message), _body(message), Dict{Symbol,Any}())
end

Request(method::Symbol, uri::String, query::String, headers::Dict{String,String}, body::String, context::Dict{Symbol,Any}) =
    Request(method, uri, query, [k => v for (k, v) in headers], body, context)

function LazyRequest(message::MgHttpMessage)
    return LazyRequest(_method(message), _uri(message), message, Dict{Symbol,Any}())
end

body(req::Request) = getfield(req, :body)
body(req::LazyRequest) = _tostring(getfield(req, :message).body)

context(req::Request) = getfield(req, :context)
context(req::LazyRequest) = getfield(req, :context)

query(req::Request) = getfield(req, :query)
query(req::LazyRequest) = _tostring(getfield(req, :message).query)

headers(req::Request) = getfield(req, :headers)
headers(req::LazyRequest) = _headers(getfield(req, :message))

function Base.getproperty(req::AbstractRequest, s::Symbol)
    s === :query   && return query(req)
    s === :body    && return body(req)
    s === :headers && return headers(req)
    s === :context && return context(req)
    return getfield(req, s)
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

    return Symbol(lowercase(to_string(str)))
end

function _headers(message::MgHttpMessage)
    pairs = Pair{String,String}[]
    for h in message.headers
        if h.name.buf != C_NULL && h.name.len > 0 && h.val.buf != C_NULL && h.val.len > 0
            name = lowercase(to_string(h.name))
            value = to_string(h.val)
            push!(pairs, name => value)
        end
    end
    return pairs
end

const ContentType = (
    text   = "Content-Type: text/plain; charset=utf-8\r\n",
    html   = "Content-Type: text/html; charset=utf-8\r\n",
    json   = "Content-Type: application/json; charset=utf-8\r\n",
    xml    = "Content-Type: application/xml; charset=utf-8\r\n",
    css    = "Content-Type: text/css; charset=utf-8\r\n",
    js     = "Content-Type: application/javascript; charset=utf-8\r\n"
)
