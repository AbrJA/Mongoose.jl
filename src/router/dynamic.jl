"""
    HTTP router — trie-based path matching with fixed-route fast path.
"""

# Handler defined in types.jl

# --- MethodHandlers: fixed-slot dispatch for HTTP methods ---

"""
    MethodHandlers — Fixed-slot storage for HTTP method handlers.

Uses struct fields instead of Dict for O(1) branch-predicted dispatch
with zero allocation. Each field is `Union{Nothing,Handler}`.
"""
mutable struct MethodHandlers
    get::Union{Nothing,Handler}
    post::Union{Nothing,Handler}
    put::Union{Nothing,Handler}
    delete::Union{Nothing,Handler}
    patch::Union{Nothing,Handler}
    options::Union{Nothing,Handler}
    head::Union{Nothing,Handler}
    MethodHandlers() = new(nothing, nothing, nothing, nothing, nothing, nothing, nothing)
end

@inline function _get_handler(mh::MethodHandlers, method::Symbol)
    method === :get     && return mh.get
    method === :post    && return mh.post
    method === :put     && return mh.put
    method === :delete  && return mh.delete
    method === :patch   && return mh.patch
    method === :options && return mh.options
    method === :head    && return mh.head
    return nothing
end

@inline function _set_handler!(mh::MethodHandlers, method::Symbol, @nospecialize(handler::Handler))
    method === :get     && (mh.get = handler; return)
    method === :post    && (mh.post = handler; return)
    method === :put     && (mh.put = handler; return)
    method === :delete  && (mh.delete = handler; return)
    method === :patch   && (mh.patch = handler; return)
    method === :options && (mh.options = handler; return)
    method === :head    && (mh.head = handler; return)
    throw(RouteError("Invalid HTTP method: $method"))
end

@inline function _has_handlers(mh::MethodHandlers)
    return mh.get !== nothing || mh.post !== nothing || mh.put !== nothing ||
           mh.delete !== nothing || mh.patch !== nothing || mh.options !== nothing ||
           mh.head !== nothing
end

"""
    Node — A node in the radix trie for path-segment matching.
    Uses Vector for children (cache-friendly for small fanout) and
    MethodHandlers for O(1) method dispatch.
"""
mutable struct Node
    children::Vector{Pair{String,Node}}          # static segment children
    dynamic::Union{Nothing,Node}                 # parameter segment child (:param)
    param::Union{Nothing,String}                 # parameter name (if dynamic node)
    param_type::Type                             # parameter type
    param_names::Vector{String}                  # parameter names in order
    handlers::MethodHandlers                     # HTTP method → handler
    Node() = new(Pair{String,Node}[], nothing, nothing, String, String[], MethodHandlers())
end

# --- Vector-based child lookup (faster than Dict for <10 children) ---

@inline function _find_child(children::Vector{Pair{String,Node}}, key::AbstractString)
    @inbounds for i in 1:length(children)
        children[i].first == key && return children[i].second
    end
    return nothing
end

"""
    FixedRoute — A leaf node for static routes.
"""
struct FixedRoute
    handlers::MethodHandlers
    FixedRoute() = new(MethodHandlers())
end

"""
    Router — Trie-based dynamic HTTP + WebSocket router.
"""
struct Router <: AbstractRouter
    node::Node
    fixed::Dict{String,FixedRoute}
    ws_routes::Dict{String,WsEndpoint}
    Router() = new(Node(), Dict{String,FixedRoute}(), Dict{String,WsEndpoint}())
end

# (Matched, match_route, route!, etc...)
struct Matched
    handlers::MethodHandlers
    params::Vector{Any}
end

const EMPTY_PARAMS = Any[]
const VALID_METHODS = Set([:get, :post, :put, :patch, :delete, :options, :head])

const PARAM_TYPES = Dict{String,Type}(
    "String" => String, "Int" => Int, "Int64" => Int64, "Int32" => Int32,
    "Float64" => Float64, "Float32" => Float32, "Bool" => Bool,
    "UInt" => UInt, "UInt64" => UInt64
)

function match_route(router::Router, method::Symbol, path::AbstractString)
    clean = strip_query(path)
    if (route = get(router.fixed, clean, nothing)) !== nothing
        return Matched(route.handlers, EMPTY_PARAMS)
    end
    params = Any[]
    return _match(router.node, clean, 1, method, params)
end

@inline function _match(node::Node, path::AbstractString, path_idx::Int, method::Symbol, params::Vector{Any})
    seg, next_idx = next_segment(path, path_idx)
    if seg === nothing
        return _has_handlers(node.handlers) ? Matched(node.handlers, params) : nothing
    end

    static_node = _find_child(node.children, seg)
    if static_node !== nothing
        result = _match(static_node, path, next_idx, method, params)
        result !== nothing && return result
    end

    if (dyn = node.dynamic) !== nothing
        parsed = try
            _parse_param_value(seg, dyn.param_type)
        catch
            nothing
        end
        if parsed !== nothing
            push!(params, parsed)
            result = _match(dyn, path, next_idx, method, params)
            result !== nothing && return result
            pop!(params)
        end
    end
    return nothing
end

function route!(router::Router, method::Symbol, path::AbstractString, @nospecialize(handler::Function))
    if method ∉ VALID_METHODS
        throw(RouteError("Invalid HTTP method: $(String(method))"))
    end
    _register_route!(router, method, path, handler)
    return router
end

function _register_route!(router::Router, method::Symbol, path::AbstractString, @nospecialize(wrapped::Handler))
    if !occursin(':', path)
        if !haskey(router.fixed, path)
            router.fixed[path] = FixedRoute()
        end
        _set_handler!(router.fixed[path].handlers, method, wrapped)
        return router
    end

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
            child = _find_child(node.children, seg)
            if child === nothing
                child = Node()
                push!(node.children, String(seg) => child)
            end
            node = child
        end
    end
    _set_handler!(node.handlers, method, wrapped)
    return router
end

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

function _parse_param_spec(spec::AbstractString)
    idx = findfirst("::", spec)
    if idx === nothing
        return String(spec), String
    end
    name = spec[1:first(idx)-1]
    type_str = spec[last(idx)+1:end]
    T = get(PARAM_TYPES, type_str, String)
    return String(name), T
end

@inline _parse_param_value(value::AbstractString, ::Type{String}) = String(value)
@inline _parse_param_value(value::AbstractString, ::Type{T}) where {T} = Base.parse(T, String(value))
