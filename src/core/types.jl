"""
    Core abstract types and the middleware pipeline.
"""

using FunctionWrappers: FunctionWrapper

abstract type AbstractMessage end
abstract type AbstractRequest <: AbstractMessage end
abstract type AbstractResponse <: AbstractMessage end

abstract type Server end
abstract type Route end

"""
    Handler — Type alias for user route handlers.
    Wraps a callable with concrete input/output types for type stability and trim-safe AOT.
"""
const Handler = FunctionWrapper{AbstractResponse, Tuple{AbstractRequest, Dict{String,String}}}

"""
    Middleware — Type alias for middleware functions.
    A middleware takes (request, params, next) and returns a response.
    The `next` is a no-argument callable that invokes the next middleware in the chain.
"""
const Middleware = FunctionWrapper{AbstractResponse, Tuple{AbstractRequest, Dict{String,String}, FunctionWrapper{AbstractResponse, Tuple{}}}}

"""
    execute_middleware(middlewares, request, params, final_handler)

Iterative middleware pipeline execution. Avoids recursive closures and
per-call closure allocations. Builds the call chain from the inside out,
then invokes it once.
"""
function execute_middleware(middlewares::Vector{Middleware}, request::AbstractRequest, params::Dict{String,String}, final_handler::Handler)
    isempty(middlewares) && return final_handler(request, params)
    
    # Build the chain from the innermost (final handler) outward
    current::FunctionWrapper{AbstractResponse, Tuple{}} = FunctionWrapper{AbstractResponse, Tuple{}}(() -> final_handler(request, params))
    
    for i in length(middlewares):-1:1
        mw = middlewares[i]
        next = current
        current = FunctionWrapper{AbstractResponse, Tuple{}}(() -> mw(request, params, next))
    end
    
    return current()
end
