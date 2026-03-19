"""
    Event dispatching — single C callback that dispatches to typed handlers.
"""

"""
    select_server(conn) → Server or nothing

Retrieve the Server instance associated with a connection via `fn_data`.
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
Uses manual union splitting for trim-safe AOT compilation.
"""
function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})::Cvoid
    ev == MG_EV_POLL && return nothing
    
    server = select_server(conn)
    server === nothing && return nothing

    # Manual union splitting for exact JIT concrete types to satisfy trim-safe AOT
    if server isa AsyncServer{Router, NoApp}
        _invoke_dispatch(server::AsyncServer{Router, NoApp}, ev, conn, ev_data)
    elseif server isa SyncServer{Router, NoApp}
        _invoke_dispatch(server::SyncServer{Router, NoApp}, ev, conn, ev_data)
    else
        @error "event_handler: Unhandled server type in JIT callback. Custom apps must provide their own c_handler"
    end
    
    return nothing
end

"""
    _invoke_dispatch(server, ev, conn, ev_data)

Route events to typed `handle_event!` methods.
Only known event codes are dispatched to avoid dynamic Val instantiation.
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
    end
    return nothing
end

handle_event!(server::Server, ::Val, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid}) = nothing
