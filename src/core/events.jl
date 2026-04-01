"""
    _callbackev(conn, ev, ev_data) → Cvoid

The single C callback registered with Mongoose via `@cfunction`.
"""
function _callbackev(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    ev == MG_EV_POLL && return nothing

    fn_data = mg_conn_get_fn_data(conn)
    fn_data == C_NULL && return nothing

    server = Base.unsafe_pointer_to_objref(fn_data)
    try
        _dispatchev(server, ev, conn, ev_data)
    catch e
        @error "Event handler error" exception = (e, catch_backtrace())
    end

    return nothing
end

"""
    _dispatchev(server, ev, conn, ev_data)
"""
@inline function _dispatchev(@nospecialize(server), ev::Cint, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid})
    if ev == MG_EV_HTTP_MSG
        _onevent!(server, Val(MG_EV_HTTP_MSG), conn, ev_data)
    elseif ev == MG_EV_WS_OPEN
        _onevent!(server, Val(MG_EV_WS_OPEN), conn, ev_data)
    elseif ev == MG_EV_WS_MSG
        _onevent!(server, Val(MG_EV_WS_MSG), conn, ev_data)
    elseif ev == MG_EV_WS_CTL
        _onevent!(server, Val(MG_EV_WS_CTL), conn, ev_data)
    elseif ev == MG_EV_CLOSE
        _onevent!(server, Val(MG_EV_CLOSE), conn, ev_data)
    end
    return nothing
end

_onevent!(server::AbstractServer, ::Val, conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid}) = nothing

# JIT-only fallbacks — <:AbstractRouter matches Router; @router overrides for specific static types
_cfnasync(::Type{<:AbstractRouter}) = @cfunction(_callbackev, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
_cfnsync(::Type{<:AbstractRouter}) = @cfunction(_callbackev, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
