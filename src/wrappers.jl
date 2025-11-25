using Mongoose_jll

# Constants

const MG_EV_HTTP_MSG = Cint(11) # For full requests
const MG_EV_POLL = Cint(2) # For polling
const MG_MAX_HTTP_HEADERS = 30 # Maximum number of HTTP headers allowed
const MG_EV_CLOSE = Cint(9) # For closing connections

const MgConnection = Ptr{Cvoid} # Pointer to a generic C void type

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

to_string(str::MgStr) = (str.ptr == C_NULL || str.len == 0) ? "" : unsafe_string(pointer(str.ptr), str.len)

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

    function MgHttpMessage(ev_data::Ptr{Cvoid})
        ev_data == C_NULL && error("ev_data for HTTP message is NULL")
        return unsafe_load(Ptr{MgHttpMessage}(ev_data))
    end
end

"""
    mg_mng_init!(mgr::Ptr{Cvoid})
    Initializes the Mongoose manager.
"""
function mg_mgr_init!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_init, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

"""
    mg_mgr_free!(mgr::Ptr{Cvoid})
    Frees the Mongoose manager.
"""
function mg_mgr_free!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_free, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

"""
    mg_http_listen(mgr::Ptr{Cvoid}, url::String, handler::Ptr{Cvoid}, userdata::Ptr{Cvoid})
    Starts listening for HTTP requests on the specified URL.
    # Arguments
    - `mgr::Ptr{Cvoid}`: A pointer to the Mongoose manager.
    - `url::String`: The URL to listen on (e.g., "http://localhost:8080").
    - `handler::Ptr{Cvoid}`: A pointer to the event handler function.
    - `fn_data::Ptr{Cvoid}`: A pointer to user data that will be passed to the event handler.
"""
function mg_http_listen(mgr::Ptr{Cvoid}, url::String, handler::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    ccall((:mg_http_listen, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}, Ptr{Cvoid}), mgr, Base.unsafe_convert(Cstring, url), handler, fn_data)
end

"""
    mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Int)
    Polls the Mongoose manager for events.
    # Arguments
    - `mgr::Ptr{Cvoid}`: A pointer to the Mongoose manager.
    - `timeout_ms::Int`: The maximum number of milliseconds to wait for events.
"""
function mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Int)
    ccall((:mg_mgr_poll, libmongoose), Cint, (Ptr{Cvoid}, Cint), mgr, Cint(timeout_ms))
end

"""
    mg_http_reply(conn::MgConnection, status::Int, headers::String, body::String)::Cvoid
    Sends an HTTP reply to a connected client. It constructs and sends an HTTP response including the status code, headers, and body.
    # Arguments
    - `conn::MgConnection`: A pointer to the Mongoose connection to which the reply should be sent.
    - `status::Int`: The HTTP status code (e.g., 200 for OK, 404 for Not Found).
    - `headers::String`: A string containing HTTP headers, separated by `\\r\\n`. For example: `"Content-Type: text/plain\\r\\nCustom-Header: value\\r\\n"`.
    - `body::String`: The body of the HTTP response.
"""
function mg_http_reply(conn::MgConnection, status::Int, headers::String, body::String)
    ccall((:mg_http_reply, libmongoose), Cvoid, (Ptr{Cvoid}, Cint, Cstring, Cstring), conn, Cint(status), Base.unsafe_convert(Cstring, headers), Base.unsafe_convert(Cstring, body))
end

"""
    mg_conn_get_fn_data(conn::MgConnection)
    Returns a pointer to user data associated with the specified connection.
    # Arguments
    - `conn::MgConnection`: A pointer to the Mongoose connection.
"""
function mg_conn_get_fn_data(conn::MgConnection)
    ccall((:mg_conn_get_fn_data, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid},), conn)
end

"""
    mg_log_set_level(level::Integer)
    Set Mongoose's global log verbosity level. Lower numbers mean less output.
    # Levels
    - `0` = MG_LL_NONE — No logs
    - `1` = MG_LL_ERROR — Errors only
    - `2` = MG_LL_INFO — Errors and info messages
    - `3` = MG_LL_DEBUG — Errors, info, and debug details
    - `4` = MG_LL_VERBOSE — Everything and more
"""
function mg_log_set_level(level::Integer)
    ptr = cglobal((:mg_log_level, libmongoose), Cint)
    unsafe_store!(ptr, Cint(level))
end
