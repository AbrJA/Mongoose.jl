"""
    Core abstract types and the middleware pipeline.
"""

abstract type AbstractMessage end
abstract type AbstractRequest <: AbstractMessage end
abstract type AbstractResponse <: AbstractMessage end

abstract type AbstractServer end

"""
    Handler — Type alias for user route handlers.
    Stored as plain Function for JIT mode. For trim-safe AOT, use the @router macro instead.
"""
const Handler = Function

abstract type Middleware end

# Interface fallback — subtypes must implement the call operator
function (mw::Middleware)(::AbstractRequest, ::Vector{Any}, ::Any)
    error("$(typeof(mw)) must implement (mw::$(typeof(mw)))(request, params, next)")
end

"""
    execute_middleware(middlewares, request, params, final_handler)

Iterative middleware pipeline execution. Builds the call chain from the inside out,
then invokes it once.
"""
function execute_middleware(middlewares::Vector{Middleware}, request::AbstractRequest, params::Vector{Any}, final_handler::Function)
    isempty(middlewares) && return final_handler(request, params...)

    # Build the chain from the innermost (final handler) outward
    current = () -> final_handler(request, params...)

    for i in length(middlewares):-1:1
        mw = middlewares[i]
        next = current
        current = () -> mw(request, params, next)
    end

    return current()
end
