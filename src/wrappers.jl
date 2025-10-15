using Mongoose_jll

"""
    MgConnection
    A type alias for a pointer to a Mongoose connection. This is used to represent a connection to a client in the Mongoose server.
"""
const MgConnection = Ptr{Cvoid} # Pointer to a generic C void type

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
    mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Integer)
    Polls the Mongoose manager for events.
    # Arguments
    - `mgr::Ptr{Cvoid}`: A pointer to the Mongoose manager.
    - `timeout_ms::Integer`: The maximum number of milliseconds to wait for events.
"""
function mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Integer)
    ccall((:mg_mgr_poll, libmongoose), Cint, (Ptr{Cvoid}, Cint), mgr, Cint(timeout_ms))
end

"""
    mg_http_reply(conn::MgConnection, status::Integer, headers::AbstractString, body::AbstractString)::Cvoid
    Sends an HTTP reply to a connected client. It constructs and sends an HTTP response including the status code, headers, and body.
    # Arguments
    - `conn::MgConnection`: A pointer to the Mongoose connection to which the reply should be sent.
    - `status::Integer`: The HTTP status code (e.g., 200 for OK, 404 for Not Found).
    - `headers::AbstractString`: A string containing HTTP headers, separated by `\\r\\n`. For example: `"Content-Type: text/plain\\r\\nCustom-Header: value\\r\\n"`.
    - `body::AbstractString`: The body of the HTTP response.
"""
function mg_http_reply(conn::MgConnection, status::Integer, headers::AbstractString, body::AbstractString)
    ccall((:mg_http_reply, libmongoose), Cvoid, (Ptr{Cvoid}, Cint, Cstring, Cstring), conn, Cint(status), Base.unsafe_convert(Cstring, String(headers)), Base.unsafe_convert(Cstring, String(body)))
end

"""
    mg_json_reply(conn::MgConnection, status::Integer, body::AbstractString)
    This is a convenience function that calls `mg_http_reply` with the `Content-Type` header set to `application/json`.
"""
function mg_json_reply(conn::MgConnection, status::Integer, body::AbstractString)
    mg_http_reply(conn, status, "Content-Type: application/json\r\n", body)
end

"""
    mg_text_reply(conn::MgConnection, status::Integer, body::AbstractString)
    This is a convenience function that calls `mg_http_reply` with the `Content-Type` header set to `text/plain`.
"""
function mg_text_reply(conn::MgConnection, status::Integer, body::AbstractString)
    mg_http_reply(conn, status, "Content-Type: text/plain\r\n", body)
end
