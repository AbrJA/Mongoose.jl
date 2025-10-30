"""
    struct MgStr
        ptr::Cstring
        len::Csize_t
    end

    A Julia representation of Mongoose's `struct mg_str` which is a view into a string buffer. It's used to represent strings returned by Mongoose.

    # Fields
    - `ptr::Cstring`: A pointer to the beginning of the string data in memory.
    - `len::Csize_t`: The length of the string in bytes.
"""
struct MgStr
    ptr::Cstring # Pointer to the string data
    len::Csize_t # Length of the string
end

const MG_MAX_HTTP_HEADERS = 30 # Maximum number of HTTP headers allowed

"""
    struct MgHttpHeader
        name::MgStr
        val::MgStr
    end
    A Julia representation of Mongoose's `struct mg_http_header`, representing a single HTTP header.
    # Fields
    - `name::MgStr`: An `MgStr` structure representing the header field name (e.g., "Content-Type").
    - `val::MgStr`: An `MgStr` structure representing the header field value (e.g., "application/json").
"""
struct MgHttpHeader
    name::MgStr
    val::MgStr
end

"""
    struct MgHttpMessage
        method::MgStr
        uri::MgStr
        query::MgStr
        proto::MgStr
        headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader}
        body::MgStr
        message::MgStr
    end
    A Julia representation of Mongoose's `struct mg_http_message`, containing parsed information about an HTTP request or response.
    # Fields
    - `method::MgStr`: The HTTP method (e.g., "GET", "POST").
    - `uri::MgStr`: The request URI (e.g., "/api/data").
    - `query::MgStr`: The query string part of the URI (e.g., "id=123").
    - `proto::MgStr`: The protocol string (e.g., "HTTP/1.1").
    - `headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader}`: A tuple of `MgHttpHeader` structs representing the HTTP headers.
    - `body::MgStr`: The body of the HTTP message.
    - `message::MgStr`: The entire raw HTTP message.
"""
struct MgHttpMessage
    method::MgStr
    uri::MgStr
    query::MgStr
    proto::MgStr
    headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader} # Array of headers
    body::MgStr
    message::MgStr
end

struct MgRequest
    id::Int
    method::String
    uri::String
    query::String
    proto::String
    headers::Dict{String, String}
    body::String
    message::String
end

struct MgResponse
    id::Int
    status::Int
    headers::Dict{String, String}
    body::String
end

function mg_request(id::Int, message::MgHttpMessage)::MgRequest
    return MgRequest(
        id,
        mg_method(message),
        mg_uri(message),
        mg_query(message),
        mg_proto(message),
        mg_headers(message),
        mg_body(message),
        mg_message(message)
    )
end

"""
    mg_method(message::MgHttpMessage) -> String
    Extracts the HTTP method from an `MgHttpMessage` as a Julia `String`.
    # Arguments
    - `message::MgHttpMessage`: The HTTP message object.
    # Returns
    `String`: The HTTP method (e.g., "GET", "POST").
"""
mg_method(message::MgHttpMessage) = mg_str(message.method)

"""
    mg_uri(message::MgHttpMessage) -> String
    Extracts the URI from an `MgHttpMessage` as a Julia `String`.
    # Arguments
    - `message::MgHttpMessage`: The HTTP message object.
    # Returns
    `String`: The request URI (e.g., "/api/users").
"""
mg_uri(message::MgHttpMessage) = mg_str(message.uri)

"""
    mg_query(message::MgHttpMessage) -> String
    Extracts the query string from an `MgHttpMessage` as a Julia `String`.
    # Arguments
    - `message::MgHttpMessage`: The HTTP message object.
    # Returns
    `String`: The query string (e.g., "param=value&id=1").
"""
mg_query(message::MgHttpMessage) = mg_str(message.query)

"""
    mg_proto(message::MgHttpMessage) -> String
    Extracts the protocol string from an `MgHttpMessage` as a Julia `String`.
    # Arguments
    - `message::MgHttpMessage`: The HTTP message object.
    # Returns
    `String`: The protocol string (e.g., "HTTP/1.1").
"""
mg_proto(message::MgHttpMessage) = mg_str(message.proto)

"""
    mg_body(message::MgHttpMessage) -> String
    Extracts the body of the HTTP message from an `MgHttpMessage` as a Julia `String`.
    # Arguments
    - `message::MgHttpMessage`: The HTTP message object.
    # Returns
    `String`: The body content of the HTTP message.
"""
mg_body(message::MgHttpMessage) = mg_str(message.body)

"""
    mg_message(message::MgHttpMessage) -> String
    Extracts the entire raw HTTP message from an `MgHttpMessage` as a Julia `String`.
    # Arguments
    - `message::MgHttpMessage`: The HTTP message object.
    # Returns
    `String`: The complete raw HTTP message string.
"""
mg_message(message::MgHttpMessage) = mg_str(message.message)

"""
    mg_headers(message::MgHttpMessage) -> Dict{String, String}
    Extracts all HTTP headers from an `MgHttpMessage` into a Julia `Dict{String, String}`.
    # Arguments
    - `message::MgHttpMessage`: The HTTP message object.
    # Returns
    `Dict{String, String}`: A dictionary where keys are header names and values are header values.
"""
function mg_headers(message::MgHttpMessage)::Dict{String, String}
    headers = Dict{String, String}()
    sizehint!(headers, length(message.headers))
    for header in message.headers
        # header.name.ptr == C_NULL && break # Early termination
        # if header.name.len > 0
        #     name = mg_str(header.name)
        #     value = mg_str(header.val)
        #     headers[name] = value
        # end
        if header.name.ptr != C_NULL && header.name.len > 0
            name = mg_str(header.name)
            value = mg_str(header.val)
            headers[name] = value
            # if !isempty(name) && !isempty(value)
            #     headers[name] = value
            # end
        end
    end
    return headers
end

function mg_http_message(ev_data::Ptr{Cvoid})::MgHttpMessage
    if ev_data == C_NULL
        error("ev_data for HTTP message is NULL")
    end
    return Base.unsafe_load(Ptr{MgHttpMessage}(ev_data))
end

mg_str(str::MgStr) = (str.ptr == C_NULL || str.len == 0) ? "" : Base.unsafe_string(pointer(str.ptr), str.len)

# function mg_str(str::MgStr)::String
#     if str.ptr == C_NULL || str.len == 0
#         return ""
#     end
#     return Base.unsafe_string(pointer(str.ptr), str.len)
# end
