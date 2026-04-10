"""
    Core abstract types and the middleware pipeline.
"""

"""
    WsConn — Per-connection WebSocket state stored in `ServerCore.ws_clients`.

Combines the route URI (needed for endpoint dispatch and `on_close` callbacks)
with the last-activity timestamp (needed for idle-timeout sweeps). Using a
single dict avoids duplicate key lookups and guarantees the two values are
always in sync.

Declared `mutable` so `_wstouch!` can update `last_active` in-place without
allocating a new struct — critical for GC safety inside C callbacks.

`last_active` is `0.0` for connections created when `ws_idle_timeout == 0`.
"""
mutable struct WsConn
    const uri::String
    last_active::Float64
end

abstract type AbstractRequest end

abstract type AbstractServer end
abstract type AbstractMiddleware end
abstract type AbstractRouter end

# Interface fallback — subtypes must implement the call operator
function (mw::AbstractMiddleware)(args...)
    error("Middleware of type $(typeof(mw)) does not support the arguments provided. Expected signature: (mw)(req, params, next)")
end

"""
    _pipeline(middlewares, request, params, final_handler)

Recursive middleware pipeline execution. Each step builds one closure (for `next`)
and calls the middleware. Avoids pre-allocating N closures up front.
"""
function _pipeline(middlewares::Vector{AbstractMiddleware}, request::AbstractRequest, params::Vector{Any}, @nospecialize(final_handler::Function), idx::Int=1)
    if idx > length(middlewares)
        return final_handler(request, params...)
    end
    mw = middlewares[idx]
    return mw(request, params, () -> _pipeline(middlewares, request, params, final_handler, idx + 1))
end
