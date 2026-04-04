"""
    _callbackev(conn, ev, ev_data) → Cvoid

The single C callback registered with Mongoose via `@cfunction`.

GC safety: the server object is recovered via `unsafe_pointer_to_objref` from
`fn_data`, which was set to `pointer_from_objref(server)` during bind.
The server must remain rooted (via the global REGISTRY) for the lifetime
of the listener — otherwise GC can collect it while C still holds the pointer.

We disable GC for the duration of the callback to prevent stop-the-world
pauses under high concurrency (512+ connections) and to ensure that all
C-originated pointers (`conn`, `ev_data`, and any `MgStr.buf` inside
`MgHttpMessage`) remain valid for the entire callback scope. GC is
re-enabled after dispatch so that allocations made during handler
execution can be collected between poll cycles.
"""
function _callbackev(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    ev == MG_EV_POLL && return nothing

    fn_data = mg_conn_get_fn_data(conn)
    fn_data == C_NULL && return nothing

    GC.enable(false)
    server = Base.unsafe_pointer_to_objref(fn_data)
    try
        _dispatchev(server, ev, conn, ev_data)
    catch e
        @error "Event handler error" exception = (e, catch_backtrace())
    finally
        GC.enable(true)
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
