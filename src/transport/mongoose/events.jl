"""
    Event dispatch — routes Mongoose C events to Julia handlers.

    Single C callback per server → event type dispatch → specialized handlers.
    The callback is a closure created at bind time that captures the concrete
    server, so dispatch resolves statically (trim-safe, no registry lookup).
    ARM/AArch64/PPC64 use a constant registry callback instead (Julia codegen
    rejects closure cfunctions there).
"""

# --- Event filter (skip unhandled events without deref) ---

@inline is_handled_event(ev::Cint) = (ev == MG_EV_HTTP_MSG || ev == MG_EV_HTTP_HDRS ||
    ev == MG_EV_WS_OPEN || ev == MG_EV_WS_MSG || ev == MG_EV_WS_CTL ||
    ev == MG_EV_CLOSE || ev == MG_EV_ACCEPT)

# --- C callback entry point ---

"""
    c_event_callback(server, conn, ev, ev_data) → Cvoid

Event entry point for one server: `bind_server!` wraps this in a per-server
`@cfunction` closure that captures the concrete server type.
"""
function c_event_callback(server::AbstractServer, conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    is_handled_event(ev) || return nothing
    try
        dispatch_event(server, ev, conn, ev_data)
    catch e
        @log_error "Event handler error" e catch_backtrace()
    end
    return nothing
end

# --- Registry callback (ARM/AArch64/PPC64: closure cfunctions unsupported) ---

const _CLOSURE_CFUNCTIONS = Sys.ARCH !== :aarch64 && Sys.ARCH !== :armv7l &&
                            Sys.ARCH !== :ppc64le

const _C_EVENT_CALLBACK = Ref{Ptr{Cvoid}}(C_NULL)

function c_event_callback(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    is_handled_event(ev) || return nothing
    fn_data = mgjl_conn_get_fn_data(conn)
    fn_data == C_NULL && return nothing
    server = lookup_server(UInt(fn_data))
    server === nothing && return nothing
    try
        dispatch_event(server, ev, conn, ev_data)
    catch e
        @log_error "Event handler error" e catch_backtrace()
    end
    return nothing
end

function get_c_callback()::Ptr{Cvoid}
    _C_EVENT_CALLBACK[] == C_NULL &&
        (_C_EVENT_CALLBACK[] = @cfunction(c_event_callback, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid})))
    return _C_EVENT_CALLBACK[]
end

# --- Event routing ---

@inline function dispatch_event(server, ev::Cint, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid})
    if ev == MG_EV_ACCEPT
        on_accept(server, conn, ev_data)
    elseif ev == MG_EV_HTTP_HDRS
        on_headers(server, conn, ev_data)
    elseif ev == MG_EV_HTTP_MSG
        on_http_message(server, conn, ev_data)
    elseif ev == MG_EV_WS_OPEN
        on_ws_open(server, conn, ev_data)
    elseif ev == MG_EV_WS_MSG
        on_ws_message(server, conn, ev_data)
    elseif ev == MG_EV_WS_CTL
        on_ws_control(server, conn, ev_data)
    elseif ev == MG_EV_CLOSE
        on_connection_close(server, conn, ev_data)
    end
    return nothing
end

# --- Default handlers ---

function on_accept(server::AbstractServer, conn::MgConnection, ::Ptr{Cvoid})
    maxc = server.config.max_connections
    if maxc > 0 && length(server.runtime.conn_times) >= maxc
        # Refuse early: mgjl_conn_error marks; the poll loop closes (mg_close_conn leaks).
        mgjl_conn_error(conn, "max connections reached")
        return nothing
    end
    now = time()
    server.runtime.conn_times[conn] = now
    # Canonical "headers not complete yet" set: used by the slowloris sweep
    # and by the header-size cap (independent of `header_timeout_ms`).
    server.runtime.awaiting_headers[conn] = now
    tls = server.runtime.tls
    tls !== nothing && init_tls!(conn, tls)
    return nothing
end

# Fallbacks
on_ws_open(::AbstractServer, ::MgConnection, ::Ptr{Cvoid}) = nothing
