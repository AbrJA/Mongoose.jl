"""
    Event dispatching — single C callback that dispatches to typed handlers.
"""

"""
    event_handler(conn, ev, ev_data) → Cvoid

The single C callback registered with Mongoose via `@cfunction`.
Uses manual union splitting for trim-safe AOT compilation.
"""
function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})::Cvoid
    ev == MG_EV_POLL && return nothing

    fn_data = mg_conn_get_fn_data(conn)
    fn_data == C_NULL && return nothing

    server = Base.unsafe_pointer_to_objref(fn_data)

    # This generic handler is only used in JIT mode (no @routes macro).
    # For AOT builds, the @routes macro generates type-specific C-handlers
    # that bypass this function entirely via get_c_handler_async/sync.
    _invoke_dispatch(server, ev, conn, ev_data)

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

# JIT-only fallbacks for dynamic routing (NoApp). These are never compiled in AOT
# because @routes-based builds never instantiate NoApp, so juliac tree-shakes them.
get_c_handler_async(::Type{NoApp}) = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
get_c_handler_sync(::Type{NoApp}) = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
