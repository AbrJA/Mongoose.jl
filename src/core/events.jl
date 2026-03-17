# Helper to retrieve the Server given a connection pointer
function select_server(conn::MgConnection)
    fn_data = mg_conn_get_fn_data(conn)
    id = UInt(fn_data)
    # Could be in registry or missing if just unregistered.
    # In a real generic callback, we must handle missing gracefully.
    lock(REGISTRY_LOCK) do
        return get(REGISTRY, id, nothing)
    end
end

"""
Generic event handler registered with Mongoose.
Dispatches to specific `handle_event!` methods based on the server type and event type.
"""
function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})::Cvoid
    ev == MG_EV_POLL && return nothing # Fast path for most common event
    
    server = select_server(conn)
    server === nothing && return nothing

    # Manual Union splitting to eliminate dynamic dispatch for JuliaC --trim=safe AOT
    if server isa AsyncServer{Router}
        _invoke_dispatch(server, ev, conn, ev_data)
    elseif server isa SyncServer{Router}
        _invoke_dispatch(server, ev, conn, ev_data)
    else
        # For AOT trim-safe compilation, calling `_invoke_dispatch` on an abstract `Server`
        # causes verifier errors. Since we union-split the known concrete types above,
        # we can just ignore unknown/custom Server types in the fallback or let them opt-in 
        # by registering their own typed C-handler.
        return nothing
    end
    
    return nothing
end

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
        # For statically typed AOT compilation, we must not instantiate `Val` 
        # dynamically using a runtime variable since it creates dynamic dispatch over types.
        nothing
    end
end

# Default fallback handlers to ignore unhandled events
handle_event!(server::Server, ::Val, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid}) = nothing
