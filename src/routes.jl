abstract type Route end

mutable struct Node <: Route
    static::Dict{String,Node}                # static children
    dynamic::Union{Nothing,Node}             # parameter child
    param::Union{Nothing,String}             # parameter name
    handlers::Dict{Symbol,Function}          # HTTP verb → handler
    Node() = new(Dict{String,Node}(), nothing, nothing, Dict{Symbol,Function}())
end

struct Fixed <: Route
    handlers::Dict{Symbol,Function}
    Fixed() = new(Dict{Symbol,Function}())
end

struct Router
    node::Node
    fixed::Dict{String,Fixed}
    Router() = new(Node(), Dict{String,Fixed}())
end

abstract type RouteMatch end

struct Matched <: RouteMatch
    handler::Function
    params::Dict{String,String}
end

struct NotFound <: RouteMatch end
struct MethodNotAllowed <: RouteMatch end

function match_route(router::Router, method::Symbol, path::AbstractString)
    # Check fixed routes first
    if (route = get(router.fixed, path, nothing)) !== nothing
        if haskey(route.handlers, method)
            return Matched(route.handlers[method], Dict{String,String}())
        end
        return MethodNotAllowed()
    end
    # Check dynamic routes
    segments = split(path, '/'; keepempty=false)
    params = Dict{String,String}()
    sizehint!(params, 4)
    return _match(router.node, segments, 1, method, params)
end

@inline function _match(node::Node, segments::Vector{<:AbstractString}, idx::Int, method::Symbol, params::Dict{String,String})
    # Base case: reached end of path
    if idx > length(segments)
        if isempty(node.handlers)
            return NotFound()
        end
        if (handler = get(node.handlers, method, nothing)) !== nothing
            return Matched(handler, params)
        end
        return MethodNotAllowed()
    end
    seg = segments[idx]
    next_idx = idx + 1
    # Try static first
    if (static_node = get(node.static, seg, nothing)) !== nothing
        result = _match(static_node, segments, next_idx, method, params)
        if result isa Matched
            return result
        end
    end
    # Try dynamic
    if (dyn = node.dynamic) !== nothing
        param_name = dyn.param
        had_value = haskey(params, param_name)
        old_value = had_value ? params[param_name] : ""
        params[param_name] = seg
        result = _match(dyn, segments, next_idx, method, params)
        if result isa Matched
            return result
        end
        # Backtrack
        had_value ? (params[param_name] = old_value) : delete!(params, param_name)
    end
    return NotFound()
end

function execute_handler(router::Router, request::IdRequest)
    matched = match_route(router, request.payload.method, request.payload.uri)
    if matched isa NotFound
        response = Response(404, "Content-Type: text/plain\r\n", "404 Not Found")
        return IdResponse(request.id, response)
    end
    if matched isa MethodNotAllowed
        response = Response(405, "Content-Type: text/plain\r\n", "405 Method Not Allowed")
        return IdResponse(request.id, response)
    end
    if matched isa Matched
        try
            response = matched.handler(request.payload, matched.params)
            return IdResponse(request.id, response)
        catch e # CHECK THIS TO ALWAYS RESPOND
            @error "Route handler failed to execute" exception = (e, catch_backtrace())
            response = Response(500, "Content-Type: text/plain\r\n", "500 Internal Server Error")
            return IdResponse(request.id, response)
        end
    end
end
