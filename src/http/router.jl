"""
    HTTP router — trie-based path matching with fixed-route fast path.
    For trim-safe AOT compilation, use the `@routes` macro instead.
"""

"""
    Node — A node in the radix trie for path-segment matching.
"""
mutable struct Node <: Route
    static::Dict{String,Node}                # static segment children
    dynamic::Union{Nothing,Node}             # parameter segment child (:param)
    param::Union{Nothing,String}             # parameter name (if dynamic node)
    handlers::Dict{Symbol,Handler}           # HTTP method → typed handler
    Node() = new(Dict{String,Node}(), nothing, nothing, Dict{Symbol,Handler}())
end

"""
    Fixed — A leaf node for static (non-parameterized) routes.
    Provides O(1) lookup bypassing the trie entirely.
"""
struct Fixed <: Route
    handlers::Dict{Symbol,Handler}
    Fixed() = new(Dict{Symbol,Handler}())
end

"""
    Router — Top-level router combining fixed and dynamic routes.
"""
struct Router <: Route
    node::Node
    fixed::Dict{String,Fixed}
    Router() = new(Node(), Dict{String,Fixed}())
end

"""
    Matched — Result of a successful route match.
"""
struct Matched
    handlers::Dict{Symbol,Handler}
    params::Dict{String,String}
end

const EMPTY_PARAMS = Dict{String,String}()

const VALID_METHODS = Set([:get, :post, :put, :patch, :delete, :options, :head])

"""
    next_segment(path, start_idx) → (segment, next_idx) or (nothing, end_idx)

Extract the next path segment starting at `start_idx`, skipping leading slashes.
Returns `nothing` when no more segments remain.
"""
function next_segment(path::AbstractString, start_idx::Int)
    start_idx > lastindex(path) && return nothing, start_idx
    
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

"""
    match_route(router, method, path) → Matched or nothing

Find a matching route for the given HTTP method and path.
Tries fixed routes first (O(1) Dict lookup), then falls back to trie matching.
"""
function match_route(router::Router, method::Symbol, path::AbstractString)
    # Fast path: fixed routes (no parameters)
    if (route = get(router.fixed, path, nothing)) !== nothing
        return Matched(route.handlers, EMPTY_PARAMS)
    end
    
    params = Dict{String,String}()
    return _match(router.node, path, 1, method, params)
end

"""
    _match(node, path, path_idx, method, params) → Matched or nothing

Recursive trie traversal with backtracking for dynamic segments.
"""
@inline function _match(node::Node, path::AbstractString, path_idx::Int, method::Symbol, params::Dict{String,String})
    seg, next_idx = next_segment(path, path_idx)
    
    # Base case: end of path
    if seg === nothing
        return isempty(node.handlers) ? nothing : Matched(node.handlers, params)
    end
    
    # Try static match first (more specific)
    if (static_node = get(node.static, seg, nothing)) !== nothing
        result = _match(static_node, path, next_idx, method, params)
        result !== nothing && return result
    end
    
    # Try dynamic match (parameter capture)
    if (dyn = node.dynamic) !== nothing
        param_name = dyn.param
        had_value = haskey(params, param_name)
        old_value = had_value ? params[param_name] : ""
        
        params[param_name] = String(seg)
        result = _match(dyn, path, next_idx, method, params)
        result !== nothing && return result
        
        # Backtrack on failure
        had_value ? (params[param_name] = old_value) : delete!(params, param_name)
    end
    
    return nothing
end

"""
    route!(server, method, path, handler)

Register an HTTP request handler for a specific method and URI path.

# Arguments
- `server::Server`: The server to register the route on.
- `method::Symbol`: HTTP method (`:get`, `:post`, `:put`, `:patch`, `:delete`, `:options`, `:head`).
- `path::AbstractString`: URI path, may contain parameters (e.g., `"/users/:id"`).
- `handler::Function`: Handler with signature `(request, params) → Response`.

# Returns
The server instance for chaining.

# Examples
```julia
route!(server, :get, "/hello", (req, params) -> Response(200, "Content-Type: text/plain\\r\\n", "Hello!"))
route!(server, :get, "/users/:id", (req, params) -> Response(200, "", "User \$(params[\\"id\\"])"))
```
"""
function route!(server::Server, method::Symbol, path::AbstractString, handler::Function)
    if method ∉ VALID_METHODS
        throw(RouteError("Invalid HTTP method: $(String(method)). Valid: get, post, put, patch, delete, options, head"))
    end
    _register_route!(server, method, path, handler)
end

"""Internal: insert a handler into the router at the given method/path."""
function _register_route!(server::Server, method::Symbol, path::AbstractString, wrapped::Handler)
    router_obj = server.core.router
    
    # Fixed route (no parameters) — stored in O(1) lookup table
    if !occursin(':', path)
        if !haskey(router_obj.fixed, path)
            router_obj.fixed[path] = Fixed()
        end
        router_obj.fixed[path].handlers[method] = wrapped
        return server
    end
    
    # Dynamic route — inserted into trie
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
    
    node.handlers[method] = wrapped
    return server
end

