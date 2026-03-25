"""
    HTTP request/response types and abstract bases.
"""
abstract type AbstractRouter end

"""
    Request — Full HTTP request with owned string data.
"""
struct Request <: AbstractRequest
    method::Symbol
    uri::String
    query::String
    headers::Dict{String,String}
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
    PreRenderedResponse — Pre-formatted raw bytes.
"""
struct PreRenderedResponse <: AbstractResponse
    bytes::Vector{UInt8}
end

"""
    Tagged{T} — Connection-tagged payload for async queue routing.
"""
struct Tagged{T}
    id::Int
    payload::T
end

# --- Constructors ---

function Response(status::Int, headers::Dict{String,String}, body::String)
    return Response(status, _format_headers(headers), body)
end

struct Json end
function json end

struct Html end
function html end

struct Text end
function text end

function html(body::String; status=200, headers=Dict{String,String}())
    h = merge(Dict("Content-Type" => "text/html; charset=utf-8"), headers)
    return Response(status, h, body)
end

function text(body::String; status=200, headers=Dict{String,String}())
    h = merge(Dict("Content-Type" => "text/plain; charset=utf-8"), headers)
    return Response(status, h, body)
end

"""
    Response(::Type{Format}, body::String; status=200, headers=Dict{String,String}())    
"""

Response(::Type{Html}, body::String; status=200, headers=Dict{String,String}()) = html(body; status=status, headers=headers)

Response(::Type{Text}, body::String; status=200, headers=Dict{String,String}()) = text(body; status=status, headers=headers)

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

function ViewRequest(message::MgHttpMessage)
    return ViewRequest(_method(message), _uri(message), message, Dict{Symbol,Any}())
end

# (Accessors and FFI helpers...)
header(req::Request, name::String) = get(req.headers, lowercase(name), nothing)

@inline function _mg_str_eq_ci(s::MgStr, target::String)
    s.len != ncodeunits(target) && return false
    for i in 1:s.len
        a = unsafe_load(s.buf, i)
        b = codeunit(target, i)
        (a | 0x20) != (b | 0x20) && return false
    end
    return true
end

function header(req::ViewRequest, name::String)
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

body(req::Request) = req.body
body(req::ViewRequest) = to_string(req.message.body)

context(req::Request) = req.context
context(req::ViewRequest) = req.context

query(req::Request) = req.query
query(req::ViewRequest) = to_string(req.message.query)

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
    headers = Dict{String,String}()
    for h in message.headers
        if h.name.buf != C_NULL && h.name.len > 0 && h.val.buf != C_NULL && h.val.len > 0
            name = lowercase(to_string(h.name))
            value = to_string(h.val)
            headers[name] = value
        end
    end
    return headers
end
