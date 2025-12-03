struct Route
    handlers::Dict{String,Function}
    Route() = new(Dict{String,Function}())
end

mutable struct Router
    static::Dict{String,Route}
    dynamic::Dict{Regex,Route}
    Router() = new(Dict{String,Route}(), Dict{Regex,Route}())
end

function execute_handler(route::Route, request::IdRequest; kwargs...)
    method = request.payload.method
    if haskey(route.handlers, method)
        try
            response = route.handlers[method](request.payload; kwargs...)
            return IdResponse(request.id, response)
        catch e # CHECK THIS TO ALWAYS RESPOND
            @error "Route handler failed to execute" exception = (e, catch_backtrace())
            response = Response(500, "Content-Type: text/plain\r\n", "500 Internal Server Error")
            return IdResponse(request.id, response)
        end
    else
        response = Response(405, "Content-Type: text/plain\r\n", "405 Method Not Allowed")
        return IdResponse(request.id, response)
    end
end

function match_route(router::Router, request::IdRequest)
    if (route = get(router.static, request.payload.uri, nothing)) !== nothing
        response = execute_handler(route, request)
        return response
    end
    for (regex, route) in router.dynamic
        if (m = match(regex, request.payload.uri)) !== nothing
            response = execute_handler(route, request; params=m)
            return response
        end
    end
    response = Response(404, "Content-Type: text/plain\r\n", "404 Not Found")
    return IdResponse(request.id, response)
end

