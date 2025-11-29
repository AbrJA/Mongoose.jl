using Mongoose_jll

# Constants

const MG_EV_HTTP_MSG = Cint(11) # For full requests
const MG_EV_POLL = Cint(2) # For polling
const MG_MAX_HTTP_HEADERS = 30 # Maximum number of HTTP headers allowed
const MG_EV_CLOSE = Cint(9) # For closing connections

const MgConnection = Ptr{Cvoid} # Pointer to a generic C void type

struct MgStr
    ptr::Cstring # Pointer to the string data
    len::Csize_t # Length of the string
end

to_string(str::MgStr) = (str.ptr == C_NULL || str.len == 0) ? "" : unsafe_string(pointer(str.ptr), str.len)

struct MgHttpHeader
    name::MgStr
    val::MgStr
end

struct MgHttpMessage
    method::MgStr
    uri::MgStr
    query::MgStr
    proto::MgStr
    headers::NTuple{MG_MAX_HTTP_HEADERS,MgHttpHeader} # Array of headers
    body::MgStr
    message::MgStr

    function MgHttpMessage(ev_data::Ptr{Cvoid})
        ev_data == C_NULL && error("ev_data for HTTP message is NULL")
        return unsafe_load(Ptr{MgHttpMessage}(ev_data))
    end
end

function mg_mgr_init!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_init, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

function mg_mgr_free!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_free, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

function mg_http_listen(mgr::Ptr{Cvoid}, url::String, handler::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    ccall((:mg_http_listen, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}, Ptr{Cvoid}), mgr, Base.unsafe_convert(Cstring, url), handler, fn_data)
end

function mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Cint)
    ccall((:mg_mgr_poll, libmongoose), Cint, (Ptr{Cvoid}, Cint), mgr, timeout_ms)
end

function mg_http_reply(conn::MgConnection, status::Int, headers::String, body::String)
    ccall((:mg_http_reply, libmongoose), Cvoid, (Ptr{Cvoid}, Cint, Cstring, Cstring), conn, Cint(status), Base.unsafe_convert(Cstring, headers), Base.unsafe_convert(Cstring, body))
end

function mg_conn_get_fn_data(conn::MgConnection)
    ccall((:mg_conn_get_fn_data, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid},), conn)
end

function mg_log_set_level(level::Cint)
    ptr = cglobal((:mg_log_level, libmongoose), Cint)
    unsafe_store!(ptr, level)
end
