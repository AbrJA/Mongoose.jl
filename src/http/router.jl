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

struct Router <: Route
    node::Node
    fixed::Dict{String,Fixed}
    Router() = new(Node(), Dict{String,Fixed}())
end

struct Matched
    handlers::Dict{Symbol,Function}
    params::Dict{String,String}
end

const EMPTY_PARAMS = Dict{String,String}()

const VALID_METHODS = Set([:get, :post, :put, :patch, :delete])

function match_route(router::Router, method::Symbol, path::AbstractString)
    # Check fixed routes first
    if (route = get(router.fixed, path, nothing)) !== nothing
        return Matched(route.handlers, EMPTY_PARAMS)
    end
    
    # Check dynamic routes using zero-allocation iterator
    segments = collect(eachsplit(path, '/'; keepempty=false))  # Need array for backtracking
    
    params = Dict{String,String}()
    sizehint!(params, 4)
    
    return _match(router.node, segments, 1, method, params)
end

@inline function _match(node::Node, segments::Vector{<:AbstractString}, idx::Integer, method::Symbol, params::Dict{String,String})
    # Base case: reached end of path
    if idx > length(segments)
        return isempty(node.handlers) ? nothing : Matched(node.handlers, params)
    end
    
    seg = segments[idx]
    next_idx = idx + 1
    
    # Try static first
    if (static_node = get(node.static, seg, nothing)) !== nothing
        result = _match(static_node, segments, next_idx, method, params)
        result !== nothing && return result
    end
    
    # Try dynamic
    if (dyn = node.dynamic) !== nothing
        param_name = dyn.param
        had_value = haskey(params, param_name)
        old_value = had_value ? params[param_name] : ""
        
        params[param_name] = seg
        result = _match(dyn, segments, next_idx, method, params)
        result !== nothing && return result
        
        # Backtrack
        had_value ? (params[param_name] = old_value) : delete!(params, param_name)
    end
    
    return nothing
end

"""
    route!(server::Server, method::Symbol, path::String, handler::Function)
    Registers an HTTP request handler for a specific method and URI.
"""
function route!(server::Server, method::Symbol, path::AbstractString, handler::Function)
    if method ∉ VALID_METHODS
        throw(RouteError("Invalid HTTP method: $method"))
    end
    
    router_obj = server.core.router
    
    if !occursin(':', path)
        if !haskey(router_obj.fixed, path)
            router_obj.fixed[path] = Fixed()
        end
        router_obj.fixed[path].handlers[method] = handler
        return server
    end
    
    segments = eachsplit(path, '/'; keepempty=false)
    node = router_obj.node
    
    for seg in segments
        if startswith(seg, ':')
            param = seg[2:end]
            if (dyn = node.dynamic) === nothing
                dyn = Node()
                dyn.param = param
                node.dynamic = dyn
            elseif dyn.param != param
                throw(RouteError("Parameter conflict: :$param vs existing :$(dyn.param)"))
            end
            node = dyn
        else
            if (child = get(node.static, seg, nothing)) === nothing
                child = Node()
                node.static[seg] = child
            end
            node = child
        end
    end
    
    node.handlers[method] = handler
    return server
end
