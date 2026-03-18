struct HttpRequest <: AbstractRequest
    method::Symbol
    uri::String
    query::String
    headers::Dict{String,String}
    body::String
end

struct ViewRequest <: AbstractRequest
    method::Symbol
    uri::String
    message::MgHttpMessage
end

struct HttpResponse <: AbstractResponse
    status::Int
    headers::String
    body::String
end

struct PreRenderedResponse <: AbstractResponse
    bytes::Vector{UInt8}
end

# Backward compatibility aliases
const Request = HttpRequest
const Response = HttpResponse

# Connection tagged requests for async queues
struct IdRequest{R <: AbstractRequest}
    id::Int
    payload::R
end

struct IdResponse{R <: AbstractResponse}
    id::Int
    payload::R
end

function HttpResponse(status::Int, headers::Dict{String,String}, body::String)
    return HttpResponse(status, to_headers(headers), body)
end

function HttpRequest(message::MgHttpMessage)
    return HttpRequest(_method(message), _uri(message), _query(message), _headers(message), _body(message))
end

function ViewRequest(message::MgHttpMessage)
    return ViewRequest(_method(message), _uri(message), message)
end

function header(req::ViewRequest, name::String)
    for header in req.message.headers
        if header.name.ptr != C_NULL && header.name.len > 0 && header.val.ptr != C_NULL && header.val.len > 0
            h_name = to_string(header.name)
            if lowercase(h_name) == lowercase(name)
                return to_string(header.val)
            end
        end
    end
    return nothing
end

body(req::ViewRequest) = to_string(req.message.body)
query(req::ViewRequest) = to_string(req.message.query)

# Standardize getters for both types
header(req::HttpRequest, name::String) = get(req.headers, name, nothing)
body(req::HttpRequest) = req.body
query(req::HttpRequest) = req.query

# Internal helpers
_method(m::MgHttpMessage) = _method_to_symbol(m.method)
_uri(m::MgHttpMessage) = to_string(m.uri)
_query(m::MgHttpMessage) = to_string(m.query)
_proto(m::MgHttpMessage) = to_string(m.proto)
_body(m::MgHttpMessage) = to_string(m.body)
_message(m::MgHttpMessage) = to_string(m.message)

function _method_to_symbol(str::MgStr)
    (str.ptr == C_NULL || str.len == 0) && return :unknown
    len = str.len
    ptr = Ptr{UInt8}(str.ptr)
    b1 = unsafe_load(ptr, 1)

    if b1 == 0x47  # 'G'
        len == 3 && unsafe_load(ptr, 2) == 0x45 && return :get # GET
    elseif b1 == 0x50  # 'P'
        if len == 3 && unsafe_load(ptr, 2) == 0x55 && return :put # PUT
        elseif len == 4 && unsafe_load(ptr, 2) == 0x4F && return :post # POST
        elseif len == 5 && unsafe_load(ptr, 2) == 0x41 && return :patch # PATCH
        end
    elseif b1 == 0x44  # 'D'
        len == 6 && unsafe_load(ptr, 2) == 0x45 && return :delete # DELETE
    end
    
    return Symbol(lowercase(to_string(str)))
end

function _headers(message::MgHttpMessage)
    headers = Dict{String,String}()
    for header in message.headers
        if header.name.ptr != C_NULL && header.name.len > 0 && header.val.ptr != C_NULL && header.val.len > 0
            name = to_string(header.name)
            value = to_string(header.val)
            headers[name] = value
        end
    end
    return headers
end
