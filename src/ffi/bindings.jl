"""
    FFI bindings — all `ccall` wrappers for the Mongoose C library.
"""

"""
    mg_mgr_init!(mgr) — Initialize a Mongoose manager.
"""
function mg_mgr_init!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_init, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

"""
    mg_mgr_free!(mgr) — Free all resources held by a Mongoose manager.
"""
function mg_mgr_free!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_free, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

"""
    mg_http_listen(mgr, url, handler, fn_data) — Start listening for HTTP connections.
    Returns a connection pointer, or C_NULL on failure.
"""
function mg_http_listen(mgr::Ptr{Cvoid}, url::String, handler::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    ccall((:mg_http_listen, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}, Ptr{Cvoid}), mgr, url, handler, fn_data)
end

"""
    mg_mgr_poll(mgr, timeout_ms) — Poll the manager for events within the given timeout.
"""
function mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Cint)
    ccall((:mg_mgr_poll, libmongoose), Cint, (Ptr{Cvoid}, Cint), mgr, timeout_ms)
end

"""
    mg_http_reply(conn, status, headers, body) — Send an HTTP response.
"""
function mg_http_reply(conn::MgConnection, status::Int, headers::String, body::String)
    ccall((:mg_http_reply, libmongoose), Cvoid, (Ptr{Cvoid}, Cint, Cstring, Cstring, Cstring), conn, Cint(status), headers, "%s", body)
end

"""
    mg_ws_send(conn, buf, op) — Send a WebSocket frame (text or binary).
"""
function mg_ws_send(conn::MgConnection, buf::String, op::Cint)
    ccall((:mg_ws_send, libmongoose), Cvoid, (Ptr{Cvoid}, Cstring, Csize_t, Cint), conn, buf, sizeof(buf), op)
end

function mg_ws_send(conn::MgConnection, buf::Vector{UInt8}, op::Cint)
    ccall((:mg_ws_send, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Cint), conn, pointer(buf), sizeof(buf), op)
end

"""
    mg_ws_upgrade(conn, hm, fmt) — Upgrade an HTTP connection to WebSocket.
"""
function mg_ws_upgrade(conn::MgConnection, hm::Ptr{Cvoid}, fmt::Ptr{Cvoid}=C_NULL)
    ccall((:mg_ws_upgrade, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring), conn, hm, fmt)
end

"""
    mg_conn_get_fn_data(conn) — Retrieve the user-data pointer associated with a connection.
"""
function mg_conn_get_fn_data(conn::MgConnection)
    ccall((:mg_conn_get_fn_data, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid},), conn)
end

"""
    mg_log_set_level(level) — Set the Mongoose C library log level.
"""
function mg_log_set_level(level::Cint)
    ptr = cglobal((:mg_log_level, libmongoose), Cint)
    unsafe_store!(ptr, level)
end

"""
    mg_send(conn, buf) — Send raw bytes on a connection.
"""
function mg_send(conn::MgConnection, buf::Vector{UInt8})
    ccall((:mg_send, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), conn, pointer(buf), sizeof(buf))
end
