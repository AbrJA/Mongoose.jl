"""
    HTTP request/response types and header parsing.
"""

"""
    HttpRequest — Full HTTP request with owned string data.
    All fields are eagerly parsed and safe to use anywhere (no pointer lifetime issues).
"""
struct HttpRequest <: AbstractRequest
    method::Symbol
    uri::String
    query::String
    headers::Dict{String,String}
    body::String
end

"""
    ViewRequest — Lightweight HTTP request with lazy header access.
    The underlying `MgHttpMessage` contains C pointers that are only valid
    during the current event callback. Do NOT store or queue this type.
    Used by `SyncServer` for zero-copy performance.
"""
struct ViewRequest <: AbstractRequest
    method::Symbol
    uri::String
    message::MgHttpMessage
end

"""
    HttpResponse — HTTP response with status, headers, and body.
    Headers are stored as a pre-formatted string for direct C library use.
"""
struct HttpResponse <: AbstractResponse
    status::Int
    headers::String
    body::String
end

"""
    PreRenderedResponse — Pre-formatted raw bytes to send directly via `mg_send`.
    For maximum performance when the response format is known at compile time.
"""
struct PreRenderedResponse <: AbstractResponse
    bytes::Vector{UInt8}
end

# Backward compatibility aliases
const Request = HttpRequest
const Response = HttpResponse

"""
    IdRequest{R} — Connection-tagged request for async queue routing.
"""
struct IdRequest{R <: AbstractRequest}
    id::Int
    payload::R
end

"""
    IdResponse{R} — Connection-tagged response for async queue routing.
"""
struct IdResponse{R <: AbstractResponse}
    id::Int
    payload::R
end

"""
    HttpResponse(status, headers::Dict, body) — Convenience constructor that formats headers.
"""
function HttpResponse(status::Int, headers::Dict{String,String}, body::String)
    return HttpResponse(status, to_headers(headers), body)
end

"""
    HttpRequest(message::MgHttpMessage) — Construct from C struct (allocating; copies all data).
"""
function HttpRequest(message::MgHttpMessage)
    return HttpRequest(_method(message), _uri(message), _query(message), _headers(message), _body(message))
end

"""
    ViewRequest(message::MgHttpMessage) — Construct from C struct (zero-copy for headers/body).
"""
function ViewRequest(message::MgHttpMessage)
    return ViewRequest(_method(message), _uri(message), message)
end

"""
    header(req, name) — Get a header value by name (case-insensitive). Returns `nothing` if not found.
"""
function header(req::ViewRequest, name::String)
    name_lower = lowercase(name)
    for h in req.message.headers
        if h.name.buf != C_NULL && h.name.len > 0 && h.val.buf != C_NULL && h.val.len > 0
            h_name = to_view(h.name)
            if lowercase(String(h_name)) == name_lower
                return to_string(h.val)
            end
        end
    end
    return nothing
end

header(req::HttpRequest, name::String) = get(req.headers, name, nothing)

"""
    body(req) — Get the request body as a String.
"""
body(req::ViewRequest) = to_string(req.message.body)
body(req::HttpRequest) = req.body

"""
    query(req) — Get the raw query string.
"""
query(req::ViewRequest) = to_string(req.message.query)
query(req::HttpRequest) = req.query

# --- Internal FFI helpers ---

"""Parse HTTP method into a Symbol using byte-level matching for zero-allocation."""
_method(m::MgHttpMessage) = _method_to_symbol(m.method)
_uri(m::MgHttpMessage) = to_string(m.uri)
_query(m::MgHttpMessage) = to_string(m.query)
_body(m::MgHttpMessage) = to_string(m.body)

"""
    _method_to_symbol(str::MgStr) → Symbol

Fast byte-level HTTP method parser. Verifies all bytes for correctness,
not just length and first byte.
"""
function _method_to_symbol(str::MgStr)
    (str.buf == C_NULL || str.len == 0) && return :unknown
    len = str.len
    ptr = str.buf

    b1 = unsafe_load(ptr, 1)

    if b1 == 0x47  # 'G'
        if len == 3
            unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x54 && return :get   # GET
        end
    elseif b1 == 0x50  # 'P'
        if len == 3
            unsafe_load(ptr, 2) == 0x55 && unsafe_load(ptr, 3) == 0x54 && return :put   # PUT
        elseif len == 4
            unsafe_load(ptr, 2) == 0x4F && unsafe_load(ptr, 3) == 0x53 && unsafe_load(ptr, 4) == 0x54 && return :post  # POST
        elseif len == 5
            unsafe_load(ptr, 2) == 0x41 && unsafe_load(ptr, 3) == 0x54 && unsafe_load(ptr, 4) == 0x43 && unsafe_load(ptr, 5) == 0x48 && return :patch # PATCH
        end
    elseif b1 == 0x44  # 'D'
        if len == 6
            unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x4C && unsafe_load(ptr, 4) == 0x45 && unsafe_load(ptr, 5) == 0x54 && unsafe_load(ptr, 6) == 0x45 && return :delete # DELETE
        end
    elseif b1 == 0x4F  # 'O'
        if len == 7
            unsafe_load(ptr, 2) == 0x50 && unsafe_load(ptr, 3) == 0x54 && unsafe_load(ptr, 4) == 0x49 && unsafe_load(ptr, 5) == 0x4F && unsafe_load(ptr, 6) == 0x4E && unsafe_load(ptr, 7) == 0x53 && return :options # OPTIONS
        end
    elseif b1 == 0x48  # 'H'
        if len == 4
            unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x41 && unsafe_load(ptr, 4) == 0x44 && return :head  # HEAD
        end
    end
    
    return Symbol(lowercase(to_string(str)))
end

"""
    _headers(message) → Dict{String,String}

Parse all non-empty headers from a `MgHttpMessage` into an owned Dict.
"""
function _headers(message::MgHttpMessage)
    headers = Dict{String,String}()
    for h in message.headers
        if h.name.buf != C_NULL && h.name.len > 0 && h.val.buf != C_NULL && h.val.len > 0
            name = to_string(h.name)
            value = to_string(h.val)
            headers[name] = value
        end
    end
    return headers
end
