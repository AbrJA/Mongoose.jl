"""
    _ishandled(ev) → Bool

Return `true` for Mongoose events the framework handles. Called before
`mg_conn_get_fn_data` to avoid dereferencing partially-initialized connections
(e.g. during MG_EV_OPEN on Windows with multiple threads).
"""
@inline _ishandled(ev::Cint) = (ev == MG_EV_HTTP_MSG || ev == MG_EV_WS_OPEN ||
    ev == MG_EV_WS_MSG || ev == MG_EV_WS_CTL || ev == MG_EV_CLOSE)

"""
    _callbackev(conn, ev, ev_data) → Cvoid

The single C callback registered with Mongoose via `@cfunction`.

GC safety: `fn_data` stores `objectid(server)` cast to a `Ptr{Cvoid}` — a
stable UInt64 identity token set during `_bind!`. The server is recovered via
`_lookupserver`, a normal Dict lookup that the GC fully understands. This
eliminates the concurrent-GC race that `unsafe_pointer_to_objref` creates when
the GC's marking phase writes to object headers at the same time the callback
reads them to reconstruct the Julia object.
"""
function _callbackev(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    _ishandled(ev) || return nothing

    fn_data = mg_conn_get_fn_data(conn)
    fn_data == C_NULL && return nothing

    server = _lookupserver(UInt(fn_data))
    server === nothing && return nothing
    try
        _dispatchev(server, ev, conn, ev_data)
    catch e
        _log_error("Event handler error component=eventloop", e, catch_backtrace())
    end

    return nothing
end

"""
    _dispatchev(server, ev, conn, ev_data)

Route a Mongoose event integer to the appropriate `_onevent!` specialization.
Only events handled by the framework are forwarded; all others are silently ignored.
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
