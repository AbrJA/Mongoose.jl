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

function next_segment(path::AbstractString, start_idx::Int)
    start_idx > lastindex(path) && return nothing, start_idx
    
    # skip leading slashes
    while start_idx <= lastindex(path) && path[start_idx] == '/'
        start_idx = nextind(path, start_idx)
    end
    
    start_idx > lastindex(path) && return nothing, start_idx
    
    end_idx = start_idx
    while end_idx <= lastindex(path) && path[end_idx] != '/'
        end_idx = nextind(path, end_idx)
    end
    
    return SubString(path, start_idx, prevind(path, end_idx)), end_idx
end

function match_route(router::Router, method::Symbol, path::AbstractString)
    # Check fixed routes first
    if (route = get(router.fixed, path, nothing)) !== nothing
        return Matched(route.handlers, EMPTY_PARAMS)
    end
    
    params = Dict{String,String}()
    return _match(router.node, path, 1, method, params)
end

@inline function _match(node::Node, path::AbstractString, path_idx::Int, method::Symbol, params::Dict{String,String})
    seg, next_idx = next_segment(path, path_idx)
    
    # Base case: reached end of path
    if seg === nothing
        return isempty(node.handlers) ? nothing : Matched(node.handlers, params)
    end
    
    # Try static first
    if (static_node = get(node.static, seg, nothing)) !== nothing
        result = _match(static_node, path, next_idx, method, params)
        result !== nothing && return result
    end
    
    # Try dynamic
    if (dyn = node.dynamic) !== nothing
        param_name = dyn.param
        had_value = haskey(params, param_name)
        old_value = had_value ? params[param_name] : ""
        
        params[param_name] = String(seg)
        result = _match(dyn, path, next_idx, method, params)
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
