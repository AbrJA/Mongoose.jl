abstract type AbstractMessage end
abstract type AbstractRequest <: AbstractMessage end
abstract type AbstractResponse <: AbstractMessage end

abstract type Server end
abstract type Route end

const Middleware = Function

# Simple pipeline execution of middlewares
function execute_middleware(middlewares::Vector{Middleware}, request::AbstractRequest, params::Dict{String,String}, final_handler::Function)
    # Recursively call next middleware
    function dispatch(index)
        if index > length(middlewares)
            return final_handler(request, params)
        else
            return middlewares[index](request, params, () -> dispatch(index + 1))
        end
    end
    return dispatch(1)
end
