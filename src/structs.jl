struct Request
    method::String
    uri::String
    query::String
    headers::Dict{String,String}
    body::String

    function Request(message::MgHttpMessage)
        return new(_method(message), _uri(message), _query(message), _headers(message), _body(message))
    end
end

struct IdRequest
    id::Int
    payload::Request
end

struct Response
    status::Int
    headers::String
    body::String
end

function to_string(headers::Dict{String,String})
    io = IOBuffer()
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    return String(take!(io))
end

function Response(status::Int, headers::Dict{String,String}, body::String)
    return Response(status, to_string(headers), body)
end

struct IdResponse
    id::Int
    payload::Response
end

_method(message::MgHttpMessage) = to_string(message.method)
_uri(message::MgHttpMessage) = to_string(message.uri)
_query(message::MgHttpMessage) = to_string(message.query)
_proto(message::MgHttpMessage) = to_string(message.proto)
_body(message::MgHttpMessage) = to_string(message.body)
_message(message::MgHttpMessage) = to_string(message.message)

function _headers(message::MgHttpMessage)::Dict{String,String}
    headers = Dict{String,String}()
    sizehint!(headers, length(message.headers))
    for header in message.headers
        if header.name.ptr != C_NULL && header.name.len > 0 && header.val.ptr != C_NULL && header.val.len > 0
            name = to_string(header.name)
            value = to_string(header.val)
            headers[name] = value
        end
    end
    return headers
end
