"""
    Event dispatching — single C callback that dispatches to typed handlers.
"""

"""
    select_server(conn) → Server or nothing

Retrieve the Server instance associated with a connection via `fn_data`.
Uses a lock on the global registry. This is called once per non-POLL event.
"""
@inline function select_server(conn::MgConnection)
    fn_data = mg_conn_get_fn_data(conn)
    id = UInt(fn_data)
    lock(REGISTRY_LOCK) do
        return get(REGISTRY, id, nothing)
    end
end

"""
    event_handler(conn, ev, ev_data) → Cvoid

The single C callback registered with Mongoose via `@cfunction`.
Dispatches events to typed `handle_event!` methods based on server type.

Uses manual union splitting for concrete server types to avoid dynamic dispatch,
which is required for `juliac --trim=safe` AOT compilation.
"""
function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})::Cvoid
    ev == MG_EV_POLL && return nothing # Fast path for most common event
    
    server = select_server(conn)
    server === nothing && return nothing

    # Manual union splitting for trim-safe AOT compilation.
    # The compiler needs to see concrete types to resolve all method calls statically.
    if server isa AsyncServer{Router}
        _invoke_dispatch(server, ev, conn, ev_data)
    elseif server isa SyncServer{Router}
        _invoke_dispatch(server, ev, conn, ev_data)
    else
        return nothing
    end
    
    return nothing
end

"""
    _invoke_dispatch(server, ev, conn, ev_data)

Route events to typed `handle_event!` methods using `Val` dispatch.
Only concrete event codes are dispatched — unknown events are silently ignored
to avoid dynamic `Val` instantiation (which would break trim-safe).
"""
@inline function _invoke_dispatch(server, ev::Cint, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid})
    if ev == MG_EV_HTTP_MSG
        handle_event!(server, Val(MG_EV_HTTP_MSG), conn, ev_data)
    elseif ev == MG_EV_WS_OPEN
        handle_event!(server, Val(MG_EV_WS_OPEN), conn, ev_data)
    elseif ev == MG_EV_WS_MSG
        handle_event!(server, Val(MG_EV_WS_MSG), conn, ev_data)
    elseif ev == MG_EV_WS_CTL
        handle_event!(server, Val(MG_EV_WS_CTL), conn, ev_data)
    elseif ev == MG_EV_CLOSE
        handle_event!(server, Val(MG_EV_CLOSE), conn, ev_data)
    else
        nothing
    end
end

"""
    handle_event!(server, ::Val, conn, ev_data) — Default fallback (no-op).
"""
handle_event!(server::Server, ::Val, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid}) = nothing
