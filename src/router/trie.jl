"""
    Trie-based dynamic HTTP router with fixed-route fast path.

    Design:
    - O(1) fixed-route lookup via Dict (covers ~80% of real-world routes)
    - Radix trie for parametric routes with typed segments
    - MethodMap struct for O(1) branch-predicted method dispatch (no Dict)
    - Vector{Pair} children for cache-friendly small-fanout traversal
"""

# --- Method Dispatch (struct fields instead of Dict for zero-allocation dispatch) ---

"""
    MethodMap — Fixed-slot storage for HTTP method → handler mapping.
    Uses struct fields for O(1) branch-predicted dispatch with zero allocation.
"""
mutable struct MethodMap
    get::Union{Nothing,Function}
    post::Union{Nothing,Function}
    put::Union{Nothing,Function}
    delete::Union{Nothing,Function}
    patch::Union{Nothing,Function}
    options::Union{Nothing,Function}
    head::Union{Nothing,Function}
    MethodMap() = new(nothing, nothing, nothing, nothing, nothing, nothing, nothing)
end

@inline function get_handler(mm::MethodMap, method::Symbol)::Union{Nothing,Function}
    method === :get     && return mm.get
    method === :post    && return mm.post
    method === :put     && return mm.put
    method === :delete  && return mm.delete
    method === :patch   && return mm.patch
    method === :options && return mm.options
    method === :head    && return mm.head
    return nothing
end

@inline function set_handler!(mm::MethodMap, method::Symbol, @nospecialize(handler::Function))
    method === :get     && (mm.get = handler; return)
    method === :post    && (mm.post = handler; return)
    method === :put     && (mm.put = handler; return)
    method === :delete  && (mm.delete = handler; return)
    method === :patch   && (mm.patch = handler; return)
    method === :options && (mm.options = handler; return)
    method === :head    && (mm.head = handler; return)
    throw(RouteError("Invalid HTTP method: $method"))
end

@inline function has_any_handler(mm::MethodMap)::Bool
    return mm.get !== nothing || mm.post !== nothing || mm.put !== nothing ||
           mm.delete !== nothing || mm.patch !== nothing || mm.options !== nothing ||
           mm.head !== nothing
end

# --- Trie Node ---

# Sentinel type to distinguish wildcard `*rest` from plain `:name` (both use String values)
struct WildcardSentinel end

"""
    TrieNode — Radix trie node for parametric route matching.

    Children stored as Vector{Pair} for cache locality with small fanout.
    Dynamic child represents a single `:param` segment at this level.
"""
mutable struct TrieNode
    children::Vector{Pair{String,TrieNode}}     # static segment → child
    dynamic::Union{Nothing,TrieNode}            # :param child (one per level)
    param_name::Union{Nothing,String}           # parameter name (if dynamic)
    param_type::Type                            # parameter type (String, Int, WildcardSentinel, etc.)
    handlers::MethodMap
    TrieNode() = new(Pair{String,TrieNode}[], nothing, nothing, String, MethodMap())
end

@inline function find_child(children::Vector{Pair{String,TrieNode}}, key::AbstractString)::Union{Nothing,TrieNode}
    @inbounds for i in 1:length(children)
        children[i].first == key && return children[i].second
    end
    return nothing
end

# --- Fixed Route (Dict fast path) ---

struct FixedRoute
    handlers::MethodMap
    FixedRoute() = new(MethodMap())
end

# --- Route Match Result ---

struct RouteMatch
    handlers::MethodMap
    params::Vector{Any}
end

const EMPTY_PARAMS = Any[]

# --- Router ---

"""
    Router — Dynamic trie-based HTTP + WebSocket router.

    Routes are registered at runtime via `route!()`.
    Supports: static paths, typed parameters (`:id::Int`), wildcard catch-all (`*path`).
"""
struct Router
    root::TrieNode
    fixed::Dict{String,FixedRoute}
    ws_routes::Dict{String,WsEndpoint}
    Router() = new(TrieNode(), Dict{String,FixedRoute}(), Dict{String,WsEndpoint}())
end

@inline has_ws_routes(r::Router) = !isempty(r.ws_routes)
@inline ws_endpoint(r::Router, uri::String) = get(r.ws_routes, uri, nothing)

route_count(r::Router) = string(length(r.fixed) + count_trie_handlers(r.root))

# --- Supported parameter types (extensible) ---

const VALID_METHODS = Set([:get, :post, :put, :patch, :delete, :options, :head])

const PARAM_TYPES = Dict{String,Type}(
    "String" => String, "Int" => Int, "Int64" => Int64, "Int32" => Int32,
    "Float64" => Float64, "Float32" => Float32, "Bool" => Bool,
    "UInt" => UInt, "UInt64" => UInt64
)

# --- Route Registration ---

"""
    route!(router, method, path, handler) → router

Register an HTTP route. Supports:
- Static: `/health`
- Typed params: `/users/:id::Int`
- String params: `/posts/:slug`
- Wildcard: `/*path` (must be last segment)
"""
function route!(router::Router, method::Symbol, path::AbstractString, @nospecialize(handler::Function))
    method in VALID_METHODS || throw(RouteError("Invalid HTTP method: $method"))
    _register_route!(router, method, String(path), handler)
    return router
end

function route!(router::Router, method::AbstractString, path::AbstractString, @nospecialize(handler::Function))
    route!(router, Symbol(lowercase(method)), path, handler)
end

function _register_route!(router::Router, method::Symbol, path::String, @nospecialize(handler::Function))
    # Bare "*" is a catch-all fallback (no param captured)
    if path == "*"
        if !haskey(router.fixed, "*")
            router.fixed["*"] = FixedRoute()
        end
        set_handler!(router.fixed["*"].handlers, method, handler)
        return
    end

    # Fast path: no parameters → Dict-based fixed route
    if !occursin(':', path) && !occursin('*', path)
        if !haskey(router.fixed, path)
            router.fixed[path] = FixedRoute()
        end
        set_handler!(router.fixed[path].handlers, method, handler)
        return
    end

    # Parametric path: insert into trie
    node = router.root
    for seg in eachsplit(path, '/'; keepempty=false)
        if startswith(seg, '*')
            # Wildcard catch-all: register at a special "*" child
            name = String(seg[2:end])
            if node.dynamic === nothing
                node.dynamic = TrieNode()
                node.dynamic.param_name = name
                node.dynamic.param_type = WildcardSentinel  # sentinel distinguishes from :name (String)
            end
            node = node.dynamic
        elseif startswith(seg, ':')
            spec = seg[2:end]
            param_name, param_type = _parse_param_spec(spec)
            if node.dynamic === nothing
                node.dynamic = TrieNode()
                node.dynamic.param_name = param_name
                node.dynamic.param_type = param_type
            elseif node.dynamic.param_name != param_name
                throw(RouteError("Parameter conflict at same position: :$param_name vs :$(node.dynamic.param_name)"))
            elseif node.dynamic.param_type != param_type
                throw(RouteError("Type conflict for :$param_name: $param_type vs $(node.dynamic.param_type)"))
            end
            node = node.dynamic
        else
            child = find_child(node.children, seg)
            if child === nothing
                child = TrieNode()
                push!(node.children, String(seg) => child)
            end
            node = child
        end
    end
    set_handler!(node.handlers, method, handler)
end

# --- Route Matching ---

"""
    dispatch_route(router, method, path) → Union{Nothing, RouteMatch}

Find the matching route for a given method and path.
"""
function dispatch_route(router::Router, method::Symbol, path::AbstractString)::Union{Nothing,RouteMatch}
    clean = strip_query(path)

    # Fast path: exact match in fixed routes Dict
    fixed = get(router.fixed, clean, nothing)
    if fixed !== nothing
        return RouteMatch(fixed.handlers, EMPTY_PARAMS)
    end

    # Trie traversal for parametric routes
    params = Any[]
    result = _match_trie(router.root, clean, 1, params)
    result !== nothing && return result

    # Wildcard catch-all via "*" key in fixed routes
    wildcard = get(router.fixed, "*", nothing)
    wildcard !== nothing && return RouteMatch(wildcard.handlers, EMPTY_PARAMS)

    return nothing
end

"""
    match_route_exact(router, method, path) → Union{Nothing, RouteMatch}

Match without wildcard fallback (used by static file serving to check route ownership).
"""
function match_route_exact(router::Router, method::Symbol, path::AbstractString)::Union{Nothing,RouteMatch}
    clean = strip_query(path)
    fixed = get(router.fixed, clean, nothing)
    fixed !== nothing && return RouteMatch(fixed.handlers, EMPTY_PARAMS)
    params = Any[]
    return _match_trie(router.root, clean, 1, params)
end

# --- Trie Traversal ---

function _match_trie(node::TrieNode, path::AbstractString, idx::Int, params::Vector{Any})::Union{Nothing,RouteMatch}
    seg, next_idx = _next_segment(path, idx)

    # End of path: check if current node has handlers
    if seg === nothing
        return has_any_handler(node.handlers) ? RouteMatch(node.handlers, params) : nothing
    end

    # 1. Try static children first (most specific)
    child = find_child(node.children, seg)
    if child !== nothing
        result = _match_trie(child, path, next_idx, params)
        result !== nothing && return result
    end

    # 2. Try dynamic (parametric) child
    dyn = node.dynamic
    if dyn !== nothing
        if dyn.param_type == WildcardSentinel
            # Wildcard: capture everything from current segment onwards
            # Reconstruct remaining path as a single SubString
            remainder_start = idx
            while remainder_start <= ncodeunits(path) && codeunit(path, remainder_start) == UInt8('/')
                remainder_start += 1
            end
            push!(params, SubString(path, remainder_start, ncodeunits(path)))
            return has_any_handler(dyn.handlers) ? RouteMatch(dyn.handlers, params) : (pop!(params); nothing)
        end

        parsed = _try_parse_param(seg, dyn.param_type)
        if parsed !== nothing
            push!(params, parsed)
            result = _match_trie(dyn, path, next_idx, params)
            result !== nothing && return result
            pop!(params)
        end
    end

    return nothing
end

# --- Segment Extraction ---

"""
    _next_segment(path, start_idx) → (segment::Union{Nothing,SubString}, next_idx::Int)

Extract the next path segment starting at `start_idx`. Skips leading slashes.
Returns `(nothing, idx)` when no more segments remain.
"""
@inline function _next_segment(path::AbstractString, start_idx::Int)
    len = ncodeunits(path)
    start_idx > len && return (nothing, start_idx)

    # Skip leading slashes
    while start_idx <= len && codeunit(path, start_idx) == UInt8('/')
        start_idx += 1
    end
    start_idx > len && return (nothing, start_idx)

    # Find end of segment
    end_idx = start_idx
    while end_idx <= len && codeunit(path, end_idx) != UInt8('/')
        end_idx += 1
    end

    return (SubString(path, start_idx, end_idx - 1), end_idx)
end

# --- Parameter Parsing ---

function _parse_param_spec(spec::AbstractString)
    idx = findfirst("::", spec)
    if idx === nothing
        return (String(spec), String)
    end
    name = String(spec[1:first(idx)-1])
    type_str = String(spec[last(idx)+1:end])
    T = get(PARAM_TYPES, type_str, String)
    return (name, T)
end

@inline _try_parse_param(value::AbstractString, ::Type{String}) = String(value)

@inline function _try_parse_param(value::AbstractString, ::Type{T})::Union{Nothing,T} where {T}
    return tryparse(T, String(value))
end

# --- Utilities ---

function count_trie_handlers(node::TrieNode)::Int
    count = has_any_handler(node.handlers) ? 1 : 0
    for (_, child) in node.children
        count += count_trie_handlers(child)
    end
    dyn = node.dynamic
    dyn !== nothing && (count += count_trie_handlers(dyn))
    return count
end

# --- WebSocket Registration ---

function ws!(router::Router, path::AbstractString;
             on_message::Function,
             on_open::Union{Function,Nothing}=nothing,
             on_close::Union{Function,Nothing}=nothing)
    router.ws_routes[String(path)] = WsEndpoint(on_message=on_message, on_open=on_open, on_close=on_close)
    return router
end

# --- Method-specific helpers ---
# These provide a FastAPI-style DSL: get!(router, "/path", handler)
# Compatible with App too (overloads added in server/core.jl)

"""
    get!(router_or_app, path, handler)  /  get!(handler, router_or_app, path)

Register a GET route. Do-block syntax:
```julia
get!(app, "/users/:id::Int") do req, id
    json(Dict("id" => id))
end
```
"""
function Base.get!(r::Router, path::AbstractString, @nospecialize(handler::Function))
    route!(r, :get, path, handler); return r
end
Base.get!(f::Function, r::Router, path::AbstractString) = Base.get!(r, path, f)

"""
    post!(router_or_app, path, handler)
"""
function post!(r::Router, path::AbstractString, @nospecialize(handler::Function))
    route!(r, :post, path, handler); return r
end
post!(f::Function, r::Router, path::AbstractString) = post!(r, path, f)

"""
    put!(router_or_app, path, handler)
"""
function Base.put!(r::Router, path::AbstractString, @nospecialize(handler::Function))
    route!(r, :put, path, handler); return r
end
Base.put!(f::Function, r::Router, path::AbstractString) = Base.put!(r, path, f)

"""
    patch!(router_or_app, path, handler)
"""
function patch!(r::Router, path::AbstractString, @nospecialize(handler::Function))
    route!(r, :patch, path, handler); return r
end
patch!(f::Function, r::Router, path::AbstractString) = patch!(r, path, f)

"""
    delete!(router_or_app, path, handler)
"""
function Base.delete!(r::Router, path::AbstractString, @nospecialize(handler::Function))
    route!(r, :delete, path, handler); return r
end
Base.delete!(f::Function, r::Router, path::AbstractString) = Base.delete!(r, path, f)

"""
    options!(router_or_app, path, handler)
"""
function options!(r::Router, path::AbstractString, @nospecialize(handler::Function))
    route!(r, :options, path, handler); return r
end
options!(f::Function, r::Router, path::AbstractString) = options!(r, path, f)

"""
    head!(router_or_app, path, handler)
"""
function head!(r::Router, path::AbstractString, @nospecialize(handler::Function))
    route!(r, :head, path, handler); return r
end
head!(f::Function, r::Router, path::AbstractString) = head!(r, path, f)

# --- Display ---

function Base.show(io::IO, r::Router)
    n_fixed = length(r.fixed)
    n_dynamic = count_trie_handlers(r.root)
    n_ws = length(r.ws_routes)
    print(io, "Router(")
    print(io, n_fixed + n_dynamic, " route", (n_fixed + n_dynamic) == 1 ? "" : "s")
    n_ws > 0 && print(io, ", ", n_ws, " WebSocket", n_ws == 1 ? "" : "s")
    print(io, ")")
end
