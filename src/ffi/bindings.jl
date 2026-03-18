function mg_mgr_init!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_init, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

function mg_mgr_free!(mgr::Ptr{Cvoid})
    ccall((:mg_mgr_free, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

function mg_http_listen(mgr::Ptr{Cvoid}, url::String, handler::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    ccall((:mg_http_listen, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}, Ptr{Cvoid}), mgr, url, handler, fn_data)
end

function mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Cint)
    ccall((:mg_mgr_poll, libmongoose), Cint, (Ptr{Cvoid}, Cint), mgr, timeout_ms)
end

function mg_http_reply(conn::MgConnection, status::Int, headers::String, body::String)
    ccall((:mg_http_reply, libmongoose), Cvoid, (Ptr{Cvoid}, Cint, Cstring, Cstring), conn, Cint(status), headers, body)
end

function mg_ws_send(conn::MgConnection, buf::String, op::Cint)
    ccall((:mg_ws_send, libmongoose), Cvoid, (Ptr{Cvoid}, Cstring, Csize_t, Cint), conn, buf, sizeof(buf), op)
end

function mg_ws_send(conn::MgConnection, buf::Vector{UInt8}, op::Cint)
    ccall((:mg_ws_send, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Cint), conn, pointer(buf), sizeof(buf), op)
end

function mg_ws_upgrade(conn::MgConnection, hm::Ptr{Cvoid}, fmt::Ptr{Cvoid}=C_NULL)
    ccall((:mg_ws_upgrade, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring), conn, hm, fmt)
end

function mg_conn_get_fn_data(conn::MgConnection)
    ccall((:mg_conn_get_fn_data, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid},), conn)
end

function mg_log_set_level(level::Cint)
    ptr = cglobal((:mg_log_level, libmongoose), Cint)
    unsafe_store!(ptr, level)
end

function mg_wakeup(mgr::Ptr{Cvoid}, id::Culong, arg::Ptr{Cvoid}, fn::Ptr{Cvoid})
    ccall((:mg_wakeup, libmongoose), Cvoid, (Ptr{Cvoid}, Culong, Ptr{Cvoid}, Ptr{Cvoid}), mgr, id, arg, fn)
end

function mg_send(conn::MgConnection, buf::Vector{UInt8})
    ccall((:mg_send, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), conn, pointer(buf), sizeof(buf))
end
