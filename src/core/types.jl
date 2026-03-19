"""
    Core abstract types and the middleware pipeline.
"""

abstract type AbstractMessage end
abstract type AbstractRequest <: AbstractMessage end
abstract type AbstractResponse <: AbstractMessage end

abstract type Server end
abstract type Route end

"""
    Handler — Type alias for user route handlers.
    Stored as plain Function for JIT mode. For trim-safe AOT, use the @routes macro instead.
"""
const Handler = Function

"""
    Middleware — Type alias for middleware functions.
    A middleware takes (request, params, next) and returns a response.
"""
const Middleware = Function

"""
    execute_middleware(middlewares, request, params, final_handler)

Iterative middleware pipeline execution. Builds the call chain from the inside out,
then invokes it once.
"""
function execute_middleware(middlewares::Vector{Function}, request::AbstractRequest, params::Dict{String,String}, final_handler::Function)
    isempty(middlewares) && return final_handler(request, params)
    
    # Build the chain from the innermost (final handler) outward
    current = () -> final_handler(request, params)
    
    for i in length(middlewares):-1:1
        mw = middlewares[i]
        next = current
        current = () -> mw(request, params, next)
    end
    
    return current()
end
