"""
    Event dispatch — routes Mongoose C events to Julia handlers.

    Single C callback → event type dispatch → specialized handlers.
    GC-safe: fn_data stores objectid token, recovered via registry lookup.
"""

# --- Event filter (skip unhandled events without deref) ---

@inline is_handled_event(ev::Cint) = (ev == MG_EV_HTTP_MSG || ev == MG_EV_WS_OPEN ||
    ev == MG_EV_WS_MSG || ev == MG_EV_WS_CTL || ev == MG_EV_CLOSE || ev == MG_EV_ACCEPT)

# --- C callback entry point ---

"""
    c_event_callback(conn, ev, ev_data) → Cvoid

The single @cfunction registered with the Mongoose C library.
Recovers the Julia server via registry lookup (GC-safe).
"""
function c_event_callback(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    is_handled_event(ev) || return nothing
    fn_data = mg_conn_get_fn_data(conn)
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

# --- Event routing ---

@inline function dispatch_event(@nospecialize(server), ev::Cint, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid})
    if ev == MG_EV_ACCEPT
        on_accept(server, conn, ev_data)
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

on_accept(server::AbstractServer, conn::MgConnection, ::Ptr{Cvoid}) = begin
    tls = server.core.tls
    tls !== nothing && init_tls!(conn, tls)
end

# Fallbacks
on_ws_open(::AbstractServer, ::MgConnection, ::Ptr{Cvoid}) = nothing

# --- C function pointer generation (JIT fallback) ---

cfunc_async(::Type{<:AbstractRouter}) = @cfunction(c_event_callback, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
cfunc_sync(::Type{<:AbstractRouter}) = @cfunction(c_event_callback, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
