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
function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    ev == MG_EV_POLL && return nothing # Fast path for most common event
    
    server = select_server(conn)
    server === nothing && return nothing

    # Dispatch based on event type
    # Using if/elseif here to unpack the integer into a type-stable Val
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
        handle_event!(server, Val(ev), conn, ev_data)
    end
    
    return nothing
end

# Default fallback handlers to ignore unhandled events
handle_event!(server::Server, ::Val, conn, ev_data) = nothing
