"""
    FFI bindings — all `ccall` wrappers for the Mongoose C library.

    `mgjl_*` symbols are Julia-only helpers compiled into `libmongoose` by the
    Yggdrasil build (`M/Mongoose/bundled/mg_julia_helpers.c`). They wrap C
    struct fields and variadic/printf details that would otherwise have to be
    replicated through fragile pointer arithmetic on the Julia side.
"""

# --- Manager lifecycle ---

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

# --- Listening / polling ---

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

# --- Connection helpers (mgjl_*) ---

"""
    mgjl_conn_get_fn_data(conn) — Retrieve the user-data pointer associated with a connection.
"""
function mgjl_conn_get_fn_data(conn::MgConnection)
    ccall((:mgjl_conn_get_fn_data, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid},), conn)
end

"""
    mgjl_conn_get_remote_ip(conn) → Union{Nothing,String}

Peer IP (no port) formatted by the C library. `nothing` when the connection
pointer is NULL or no address is available.
"""
function mgjl_conn_get_remote_ip(conn::MgConnection)::Union{Nothing,String}
    conn == C_NULL && return nothing
    buf = Vector{UInt8}(undef, 46)
    return GC.@preserve buf begin
        n = ccall((:mgjl_conn_get_remote_ip, libmongoose), Cint,
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), conn, pointer(buf), length(buf))
        n <= 0 ? nothing : unsafe_string(pointer(buf), Int(n))
    end
end

"""
    mgjl_conn_send_len(conn) → Int

Bytes queued in the connection's send buffer (not yet accepted by the socket).
"""
@inline function mgjl_conn_send_len(conn::MgConnection)::Int
    return Int(ccall((:mgjl_conn_send_len, libmongoose), Csize_t, (Ptr{Cvoid},), conn))
end

"""
    mgjl_conn_error(conn, msg) — Mark a connection as closing (`c->is_closing = 1`).

The next `mg_mgr_poll` reaps it through the internal close path: deregister the
fd from epoll, `closesocket`, fire `MG_EV_CLOSE`, free the struct.

Do NOT use `mg_close_conn` for this: it frees the struct immediately WITHOUT
closing the fd or removing it from the epoll set, which leaks the socket and
leaves a dangling epoll registration (the poll loop then spins or wedges on a
freed connection). `mgjl_conn_error` only marks; the poll loop closes.
"""
function mgjl_conn_error(conn::MgConnection, msg::AbstractString)
    ccall((:mgjl_conn_error, libmongoose), Cvoid, (Ptr{Cvoid}, Cstring), conn, msg)
    return nothing
end

"""
    mgjl_conn_close_after_send(conn) — Flush the send buffer, then close the connection.
"""
function mgjl_conn_close_after_send(conn::MgConnection)
    ccall((:mgjl_conn_close_after_send, libmongoose), Cvoid, (Ptr{Cvoid},), conn)
    return nothing
end

# --- HTTP responses ---

"""
    mgjl_http_reply_bin(conn, status, headers, body) — Send a binary-safe HTTP response.

Unlike `mg_http_reply`, the body is copied verbatim (embedded NUL bytes
included) and no printf formatting is involved. Mongoose derives
`Content-Length`, so the connection keeps its framing state and stays
reusable.
"""
function mgjl_http_reply_bin(conn::MgConnection, status::Integer, headers::String,
                             body::String)
    GC.@preserve body begin
        ccall((:mgjl_http_reply_bin, libmongoose), Cvoid,
              (Ptr{Cvoid}, Cint, Cstring, Ptr{UInt8}, Csize_t),
              conn, Cint(status), headers, pointer(body), ncodeunits(body))
    end
    return nothing
end

function mgjl_http_reply_bin(conn::MgConnection, status::Integer, headers::String,
                             body::AbstractVector{UInt8})
    GC.@preserve body begin
        ccall((:mgjl_http_reply_bin, libmongoose), Cvoid,
              (Ptr{Cvoid}, Cint, Cstring, Ptr{UInt8}, Csize_t),
              conn, Cint(status), headers, pointer(body), length(body))
    end
    return nothing
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
    mg_http_write_chunk(conn, chunk) — Send one HTTP chunked-transfer chunk.

An empty `chunk` sends the terminating zero-length chunk and clears mongoose's
response state (`c->is_resp = 0`).
"""
function mg_http_write_chunk(conn::MgConnection, chunk::AbstractVector{UInt8})
    GC.@preserve chunk begin
        ccall((:mg_http_write_chunk, libmongoose), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), conn, pointer(chunk), length(chunk))
    end
    return nothing
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

# --- WebSocket ---

"""
    mgjl_ws_close(conn, code, reason) — Send a RFC 6455 CLOSE frame and drain.

`code` is the status code (0 omits it); `reason` is truncated to the 125-byte
control-frame limit.
"""
function mgjl_ws_close(conn::MgConnection, code::Integer, reason::AbstractString)
    ccall((:mgjl_ws_close, libmongoose), Cvoid,
          (Ptr{Cvoid}, Cint, Cstring), conn, Cint(code), reason)
    return nothing
end

"""
    mg_ws_send(conn, buf, op) — Send a WebSocket frame (text or binary).

Passes the raw pointer and byte length so that payloads containing embedded
NUL bytes (valid in WebSocket text frames per RFC 6455) are transmitted in
full.  `GC.@preserve` keeps the buffer alive for the duration of the ccall.
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

# --- TLS ---

@inline _tls_ptr(v::String) = isempty(v) ? Ptr{UInt8}(C_NULL) : pointer(v)
@inline _tls_ptr(v::Vector{UInt8}) = isempty(v) ? Ptr{UInt8}(C_NULL) : pointer(v)
@inline _tls_len(v::String) = ncodeunits(v)
@inline _tls_len(v::Vector{UInt8}) = length(v)

"""
    mgjl_tls_init_mem(conn, ca, cert, key, name, skip_verification) — Initialize TLS.

PEM/DER material is passed as in-memory blobs (`String` or `Vector{UInt8}`), so
no `MgTlsOpts` mirror or intermediate `Ref` is needed.
"""
function mgjl_tls_init_mem(conn::MgConnection, ca, cert, key, name, skip_verification::Bool)
    GC.@preserve ca cert key name begin
        ccall((:mgjl_tls_init_mem, libmongoose), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t,
               Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Cint),
              conn,
              _tls_ptr(ca), Csize_t(_tls_len(ca)),
              _tls_ptr(cert), Csize_t(_tls_len(cert)),
              _tls_ptr(key), Csize_t(_tls_len(key)),
              _tls_ptr(name), Csize_t(_tls_len(name)),
              skip_verification ? Cint(1) : Cint(0))
    end
    return nothing
end

# --- Logging ---

"""
    mg_log_set_level(level) — Set the Mongoose C library log level.
"""
function mg_log_set_level(level::Integer)
    ptr = cglobal((:mg_log_level, libmongoose), Cint)
    unsafe_store!(ptr, Cint(level))
end

# --- ABI introspection ---

"""
    verify_abi!() — Validate the Julia struct mirrors against the linked library.

Every mirrored struct is checked by size; a mismatch means a different
Mongoose_jll build than this code was written for, which would corrupt memory
if ignored. Throws `ServerError` on mismatch.
"""
function verify_abi!()
    ok = sizeof(MgStr) == mgjl_sizeof_str() &&
         sizeof(MgHttpHeader) == mgjl_sizeof_http_header() &&
         sizeof(MgHttpMessage) == mgjl_sizeof_http_message() &&
         sizeof(MgWsMessage) == mgjl_sizeof_ws_message() &&
         sizeof(MgHttpServeOpts) == mgjl_sizeof_serve_opts()
    ok || throw(ServerError(
        "Mongoose ABI mismatch: the linked libmongoose does not match this " *
        "build of Mongoose.jl (Mongoose $(mgjl_version())). " *
        "Install a compatible Mongoose_jll."))
    return nothing
end

mgjl_sizeof_str() = ccall((:mgjl_sizeof_str, libmongoose), Csize_t, ())
mgjl_sizeof_http_header() = ccall((:mgjl_sizeof_http_header, libmongoose), Csize_t, ())
mgjl_sizeof_http_message() = ccall((:mgjl_sizeof_http_message, libmongoose), Csize_t, ())
mgjl_sizeof_ws_message() = ccall((:mgjl_sizeof_ws_message, libmongoose), Csize_t, ())
mgjl_sizeof_serve_opts() = ccall((:mgjl_sizeof_serve_opts, libmongoose), Csize_t, ())

"""
    mgjl_sizeof_mgr() → Int — Size of the C `struct mg_mgr`.
"""
@inline mgjl_sizeof_mgr()::Int = Int(ccall((:mgjl_sizeof_mgr, libmongoose), Csize_t, ()))

"""
    mgjl_version() → String — Mongoose version string of the linked library.
"""
mgjl_version() = unsafe_string(ccall((:mgjl_version, libmongoose), Cstring, ()))
