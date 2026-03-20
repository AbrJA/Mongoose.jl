"""
    HTTP router — trie-based path matching with fixed-route fast path.
    For trim-safe AOT compilation, use the `@router` macro instead.
"""

"""
    Node — A node in the radix trie for path-segment matching.
"""
mutable struct Node
    static::Dict{String,Node}                # static segment children
    dynamic::Union{Nothing,Node}             # parameter segment child (:param)
    param::Union{Nothing,String}             # parameter name (if dynamic node)
    param_type::Type                         # parameter type (String by default, or declared via :name::Type)
    param_names::Vector{String}              # parameter names in order for this route (leaf only)
    handlers::Dict{Symbol,Handler}           # HTTP method → typed handler
    Node() = new(Dict{String,Node}(), nothing, nothing, String, String[], Dict{Symbol,Handler}())
end

"""
    FixedRoute — A leaf node for static (non-parameterized) routes.
    Provides O(1) lookup bypassing the trie entirely.
"""
struct FixedRoute
    handlers::Dict{Symbol,Handler}
    FixedRoute() = new(Dict{Symbol,Handler}())
end

"""
    DynamicRouter — Top-level router combining fixed and dynamic routes.
"""
struct DynamicRouter <: AbstractRouter
    node::Node
    fixed::Dict{String, FixedRoute}
    DynamicRouter() = new(Node(), Dict{String, FixedRoute}())
end

const Router = DynamicRouter

"""
    Matched — Result of a successful route match.
"""
struct Matched
    handlers::Dict{Symbol,Handler}
    params::Vector{Any}
end

const EMPTY_PARAMS = Any[]

const VALID_METHODS = Set([:get, :post, :put, :patch, :delete, :options, :head])

# Supported param types for :name::Type syntax in route! API
const PARAM_TYPES = Dict{String,Type}(
    "String" => String,
    "Int" => Int,
    "Int64" => Int64,
    "Int32" => Int32,
    "Float64" => Float64,
    "Float32" => Float32,
    "Bool" => Bool,
    "UInt" => UInt,
    "UInt64" => UInt64,
)

"""
    _parse_param_spec(spec) → (name, type)

Parse a parameter specification like `"id"` or `"id::Int"` into name and type.
"""
function _parse_param_spec(spec::AbstractString)
    idx = findfirst("::", spec)
    if idx === nothing
        return String(spec), String
    end
    name = spec[1:first(idx)-1]
    type_str = spec[last(idx)+1:end]
    T = get(PARAM_TYPES, type_str, nothing)
    T === nothing && throw(RouteError("Unsupported parameter type: $type_str. Supported: $(join(keys(PARAM_TYPES), ", "))"))
    return String(name), T
end

"""
    _parse_param_value(value, ::Type{T}) → T

Parse a string parameter value into the declared type.
"""
@inline _parse_param_value(value::AbstractString, ::Type{String}) = String(value)
@inline _parse_param_value(value::AbstractString, ::Type{T}) where {T} = Base.parse(T, String(value))

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

    params = Any[]
    return _match(router.node, path, 1, method, params)
end

"""
    _match(node, path, path_idx, method, params) → Matched or nothing

Recursive trie traversal with backtracking for dynamic segments.
"""
@inline function _match(node::Node, path::AbstractString, path_idx::Int, method::Symbol, params::Vector{Any})
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

    # Try dynamic match (parameter capture with type parsing)
    if (dyn = node.dynamic) !== nothing
        parsed = try
            _parse_param_value(seg, dyn.param_type)
        catch
            nothing  # Type parse failed — this branch doesn't match
        end

        if parsed !== nothing
            push!(params, parsed)
            result = _match(dyn, path, next_idx, method, params)
            result !== nothing && return result

            # Backtrack on failure
            pop!(params)
        end
    end

    return nothing
end

"""
    route!(router, method, path, handler)
    route!(server, method, path, handler)

Register an HTTP request handler for a specific method and URI path.

# Arguments
- `router::DynamicRouter`: The router to register the route on (preferred).
- `server::AbstractServer`: A running server (delegates to its router).
- `method::Symbol`: HTTP method (`:get`, `:post`, `:put`, `:patch`, `:delete`, `:options`, `:head`).
- `path::AbstractString`: URI path, may contain typed parameters (e.g., `"/users/:id::Int"`).
- `handler::Function`: Handler with signature `(request, params...) → Response`.

# Parameter Types
Parameters default to `String`. Append `::Type` to declare a type:
- `:name` — captured as `String`
- `:id::Int` — parsed to `Int` at match time
- `:score::Float64` — parsed to `Float64` at match time

If a typed parameter fails to parse (e.g., `/users/abc` for `:id::Int`), the route
won't match, returning 404 instead of a runtime error in the handler.

# Examples
```julia
router = DynamicRouter()
route!(router, :get, "/hello", (req) -> Response(200, "", "Hello!"))
route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", "User \$id"))
```
"""
function route!(router::DynamicRouter, method::Symbol, path::AbstractString, handler::Function)
    if method ∉ VALID_METHODS
        throw(RouteError("Invalid HTTP method: $(String(method)). Valid: get, post, put, patch, delete, options, head"))
    end
    _register_route!(router, method, path, handler)
    return router
end

function route!(server::AbstractServer, method::Symbol, path::AbstractString, handler::Function)
    route!(server.core.router, method, path, handler)
    return server
end

"""Internal: insert a handler into the router at the given method/path."""
function _register_route!(router::DynamicRouter, method::Symbol, path::AbstractString, wrapped::Handler)
    # Fixed route (no parameters) — stored in O(1) lookup table
    if !occursin(':', path)
        if !haskey(router.fixed, path)
            router.fixed[path] = FixedRoute()
        end
        router.fixed[path].handlers[method] = wrapped
        return router
    end

    # Dynamic route — inserted into trie
    segments = eachsplit(path, '/'; keepempty=false)
    node = router.node

    for seg in segments
        if startswith(seg, ':')
            spec = seg[2:end]
            param, ptype = _parse_param_spec(spec)
            push!(node.param_names, param)
            if (dyn = node.dynamic) === nothing
                dyn = Node()
                dyn.param = param
                dyn.param_type = ptype
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
    return router
end

