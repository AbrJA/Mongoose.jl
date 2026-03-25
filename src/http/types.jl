"""
    HTTP request/response types and abstract bases.
"""
abstract type AbstractRouter end

# --- Headers ---

"""
    Headers — Ordered key-value pairs for HTTP headers.

Uses `Vector{Pair{String,String}}` internally for cache-friendly linear access,
which outperforms Dict for the typical 5-15 header entries in HTTP requests.
Preserves insertion order and supports duplicate keys (e.g. Set-Cookie).

# Usage
```julia
Headers()                                         # empty
Headers(["Content-Type" => "text/plain"])          # from pairs
```
"""
struct Headers
    pairs::Vector{Pair{String,String}}
end

Headers() = Headers(Pair{String,String}[])

function Base.get(h::Headers, key::String, default)
    @inbounds for i in 1:length(h.pairs)
        h.pairs[i].first == key && return h.pairs[i].second
    end
    return default
end

Base.isempty(h::Headers) = isempty(h.pairs)
Base.length(h::Headers) = length(h.pairs)
Base.iterate(h::Headers) = iterate(h.pairs)
Base.iterate(h::Headers, state) = iterate(h.pairs, state)
Base.push!(h::Headers, pair::Pair{String,String}) = push!(h.pairs, pair)

"""
    Request — Full HTTP request with owned string data.
"""
struct Request <: AbstractRequest
    method::Symbol
    uri::String
    query::String
    headers::Headers
    body::String
    context::Dict{Symbol,Any}
end

"""
    ViewRequest — Lightweight HTTP request with lazy header access.
"""
struct ViewRequest <: AbstractRequest
    method::Symbol
    uri::String
    message::MgHttpMessage
    context::Dict{Symbol,Any}
end

"""
    Response — HTTP response.
"""
struct Response <: AbstractResponse
    status::Int
    headers::String
    body::String
end

"""
    BinaryResponse — Pre-formatted raw bytes.
"""
struct BinaryResponse <: AbstractResponse
    bytes::Vector{UInt8}
end

## Add Factory here

"""
    Tagged{T} — Connection-tagged payload for async queue routing.
"""
struct Tagged{T}
    id::Int
    payload::T
end

# --- Constructors ---

abstract type ResponseFormat end
struct Html <: ResponseFormat end
struct Json <: ResponseFormat end
struct Text <: ResponseFormat end
struct Xml <: ResponseFormat end
struct Css <: ResponseFormat end
struct Js <: ResponseFormat end
struct Form <: ResponseFormat end
struct Octet <: ResponseFormat end

render_body(::Type{T}, body) where T = String(body)

# Mapping: This is the only place you need to update when adding new types
content_type(::Type{<:ResponseFormat}) = "application/octet-stream"
content_type(::Type{Html}) = "text/html; charset=utf-8"
content_type(::Type{Text}) = "text/plain; charset=utf-8"
content_type(::Type{Json}) = "application/json; charset=utf-8"

function Response(::Type{T}, body; status=200, headers=Headers()) where T
    h = "Content-Type: " * content_type(T) * "\r\n"
    isempty(headers) && return Response(status, h, render_body(T, body))
    return Response(status, h * _format_headers(headers), render_body(T, body))
end

Response(status::Int, headers::Headers, body::String) = Response(status, _format_headers(headers), body)

Text(body::String; status=200) = Response(Text, body; status=status)
Html(body::String; status=200) = Response(Html, body; status=status)

"""
    ContentType — Pre-formatted Content-Type headers for common MIME types.

# Usage
```julia
Response(200, ContentType.json, "{\"ok\":true}")
Response(200, ContentType.html, "<h1>Hi</h1>")
Response(200, ContentType.text, "hello")
```
"""
const ContentType = (
    text="Content-Type: text/plain\r\n",
    html="Content-Type: text/html\r\n",
    json="Content-Type: application/json\r\n",
    xml="Content-Type: application/xml\r\n",
    css="Content-Type: text/css\r\n",
    js="Content-Type: application/javascript\r\n",
    form="Content-Type: application/x-www-form-urlencoded\r\n",
    octet="Content-Type: application/octet-stream\r\n",
)

function Request(message::MgHttpMessage)
    return Request(_method(message), _uri(message), _query(message), _headers(message), _body(message), Dict{Symbol,Any}())
end

Request(method::Symbol, uri::String, query::String, headers::Dict{String,String}, body::String, context::Dict{Symbol,Any}) =
    Request(method, uri, query, Headers([k => v for (k, v) in headers]), body, context)

function ViewRequest(message::MgHttpMessage)
    return ViewRequest(_method(message), _uri(message), message, Dict{Symbol,Any}())
end

# (Accessors and FFI helpers...)
req_header(req::Request, name::String) = get(req.headers, lowercase(name), nothing)

@inline function _mg_str_eq_ci(s::MgStr, target::String)
    s.len != ncodeunits(target) && return false
    for i in 1:s.len
        a = unsafe_load(s.buf, i)
        b = codeunit(target, i)
        (a | 0x20) != (b | 0x20) && return false
    end
    return true
end

function req_header(req::ViewRequest, name::String)
    name_lower = lowercase(name)
    for h in req.message.headers
        h.name.buf == C_NULL && continue
        h.name.len == 0 && continue
        if _mg_str_eq_ci(h.name, name_lower)
            return to_string(h.val)
        end
    end
    return nothing
end

# Public alias
const header = req_header

_body(req::Request) = req.body
_body(req::ViewRequest) = to_string(req.message.body)

_context(req::Request) = req.context
_context(req::ViewRequest) = req.context

_query(req::Request) = req.query
_query(req::ViewRequest) = to_string(req.message.query)

_method(m::MgHttpMessage) = _method_to_symbol(m.method)
_uri(m::MgHttpMessage) = to_string(m.uri)
_query(m::MgHttpMessage) = to_string(m.query)
_body(m::MgHttpMessage) = to_string(m.body)

function _method_to_symbol(str::MgStr)
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
    return Headers(pairs)
end
