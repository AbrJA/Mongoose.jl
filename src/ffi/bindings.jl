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
    mg_mgr_poll(mgr, timeout) — Poll the manager for events within the given timeout.
"""
function mg_mgr_poll(mgr::Ptr{Cvoid}, timeout::Integer)
    ccall((:mg_mgr_poll, libmongoose), Cint, (Ptr{Cvoid}, Cint), mgr, Cint(timeout))
end

"""
    mg_http_reply(conn, status, headers, body) — Send an HTTP response.

String bodies only.  Binary (`Vector{UInt8}`) bodies must go through `_send!`
in handler.jl — `mg_http_reply` uses printf/strlen internally and truncates
at the first 0x00 byte.
"""
function mg_http_reply(conn::MgConnection, status::Integer, headers::String, body::String)
    ccall((:mg_http_reply, libmongoose), Cvoid, (Ptr{Cvoid}, Cint, Cstring, Cstring, Cstring), conn, Cint(status), headers, "%s", body)
end

"""
    mg_ws_send(conn, buf, op) — Send a WebSocket frame (text or binary).

For strings, passes the raw pointer and byte length so that payloads
containing embedded NUL bytes (valid in WebSocket text frames per RFC 6455)
are transmitted in full.  `GC.@preserve` keeps the buffer alive for the
duration of the ccall.
"""
function mg_ws_send(conn::MgConnection, buf::String, op::Cint)
    GC.@preserve buf begin
        ccall((:mg_ws_send, libmongoose), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Cint),
              conn, pointer(buf), ncodeunits(buf), op)
    end
end

function mg_ws_send(conn::MgConnection, buf::Vector{UInt8}, op::Cint)
    GC.@preserve buf begin
        ccall((:mg_ws_send, libmongoose), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Cint),
              conn, pointer(buf), length(buf), op)
    end
end

"""
    mg_ws_upgrade(conn, hm, fmt) — Upgrade an HTTP connection to WebSocket.

Pass `C_NULL` (the default) for `fmt` to omit the HTTP response body.
"""
function mg_ws_upgrade(conn::MgConnection, hm::Ptr{Cvoid}, fmt::Ptr{Cvoid}=C_NULL)
    ccall((:mg_ws_upgrade, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), conn, hm, fmt)
end

"""
    mg_conn_get_fn_data(conn) — Retrieve the user-data pointer associated with a connection.
"""
function mg_conn_get_fn_data(conn::MgConnection)
    ccall((:mg_conn_get_fn_data, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid},), conn)
end

"""
    mg_error(conn, msg) — Mark a connection as closing (`c->is_closing = 1`).

This is the safe way to drop a connection from outside the C callback. The
next `mg_mgr_poll` reaps it through the internal close path: deregister the fd
from epoll, `closesocket`, fire `MG_EV_CLOSE`, free the struct.

Do NOT use [`mg_close_conn`](@ref) for this: it frees the struct immediately
WITHOUT closing the fd or removing it from the epoll set, which leaks the
socket and leaves a dangling epoll registration (the poll loop then spins or
wedges on a freed connection). `mg_error` only marks; the poll loop closes.

`msg` is passed as a `%s` argument, so it may contain arbitrary text.
"""
@inline function mg_error(conn::MgConnection, msg::AbstractString)
    ccall((:mg_error, libmongoose), Cvoid, (Ptr{Cvoid}, Cstring, Cstring),
          conn, "%s", msg)
    return nothing
end

"""
    mg_close_conn(conn) — Free a connection struct immediately.

INTERNAL/FFI escape hatch only. It does not close the socket fd nor deregister
it from epoll, so calling it on a live connection leaks the fd and corrupts the
poll loop. Use [`mg_error`](@ref) to drop a live connection; this binding is
kept for completeness (e.g. connections already detached from the manager).
"""
function mg_close_conn(conn::MgConnection)
    ccall((:mg_close_conn, libmongoose), Cvoid, (Ptr{Cvoid},), conn)
end

"""
    mg_http_get_header_ptr(msg_ptr, name) → Ptr{MgStr}

Look up a request header by name (case-insensitive, as Mongoose does) without
materializing the whole header list or allocating. Returns `C_NULL` when the
header is absent; otherwise a pointer to the value span, valid only for the
duration of the current event.
"""
@inline function mg_http_get_header_ptr(msg_ptr::Ptr{Cvoid}, name::AbstractString)::Ptr{MgStr}
    ccall((:mg_http_get_header, libmongoose), Ptr{MgStr},
          (Ptr{Cvoid}, Cstring), msg_ptr, name)
end

"""
    mg_log_set_level(level) — Set the Mongoose C library log level.
"""
function mg_log_set_level(level::Integer)
    ptr = cglobal((:mg_log_level, libmongoose), Cint)
    unsafe_store!(ptr, Cint(level))
end

"""
    mg_http_serve_dir(conn, hm, opts) — Serve static files from a directory.

Handles Range, ETag, Last-Modified, pre-compressed .gz files, and directory
index automatically. Writes directly to `conn`; must be called from the event
loop thread (not from worker tasks).
"""
function mg_http_serve_dir(conn::MgConnection, hm::Ptr{Cvoid}, opts::Ref{MgHttpServeOpts})
    ccall((:mg_http_serve_dir, libmongoose), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{MgHttpServeOpts}),
          conn, hm, opts)
end

"""
    mg_send(conn, buf) — Send raw bytes on a connection.
"""
function mg_send(conn::MgConnection, buf::Vector{UInt8})
    GC.@preserve buf begin
        ccall((:mg_send, libmongoose), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), conn, pointer(buf), sizeof(buf))
    end
end

"""
    mg_tls_init(conn, opts) — Initialize TLS on a connection.

Call on `MG_EV_ACCEPT` for HTTPS servers and `MG_EV_CONNECT` for TLS clients.
"""
function mg_tls_init(conn::MgConnection, opts::Ref{MgTlsOpts})
    ccall((:mg_tls_init, libmongoose), Cvoid,
          (Ptr{Cvoid}, Ptr{MgTlsOpts}),
          conn, opts)
end
