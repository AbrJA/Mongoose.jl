"""
    Default HTTP + WebSocket router.

    Design goals: simple, readable, and easy to replace. Dispatch is:
    - O(1) exact lookup in a `Dict` of fixed routes (no dynamic segments),
    - a registration-ordered linear scan of parametric route patterns
      (`:name::Type` and `*wildcard` segments),
    - a `"*"` catch-all fallback registered in the fixed table.

    The previous radix trie was removed: its byte-level segment scanning,
    wildcard sentinels, and in-trie parameter-conflict bookkeeping were
    complexity not worth the performance for the route counts most apps have.
    Exact (static) matches always win; overlapping parametric routes resolve
    in registration order.

    Implementers wanting a different strategy should subtype `AbstractRouter`
    and implement the protocol in `router/interface.jl`.
"""

# --- Method Dispatch (struct fields instead of Dict for zero-allocation dispatch) ---

"""
    MethodMap — Fixed-slot storage for HTTP method → handler mapping.
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

# --- Fixed Route ---

struct FixedRoute
    handlers::MethodMap
    FixedRoute() = new(MethodMap())
end

# --- Parametric Route Pattern ---

"""Marker type for `*wildcard` segments."""
struct WildcardParam end

"""
    PatternSegment — one element of a parametric route pattern.

    Either a literal path segment (`is_param == false`) or a captured
    parameter (`is_param == true`) typed by `T` (`String`, `Int`, `Float64`,
    `Bool`, …, or `WildcardParam`).
"""
struct PatternSegment
    is_param::Bool
    text::String      # literal text, or parameter name when `is_param`
    T::Type           # valid when `is_param`
end

PatternSegment(text::AbstractString) = PatternSegment(false, String(text), String)
PatternSegment(name::AbstractString, ::Type{T}) where {T} = PatternSegment(true, String(name), T)

"""
    ParamRoute — a registered route whose path contains `:` or `*` segments.
"""
struct ParamRoute
    segments::Vector{PatternSegment}
    handlers::MethodMap
end

# --- Route Match Result ---

"""
    RouteMatch — result of a successful `dispatch_route`.

    `params` carries the captured path parameters. Fixed routes use an empty
    tuple (zero allocation); parametric routes use a `Vector{Any}`.
"""
struct RouteMatch
    handlers::MethodMap
    params::Any    # () or Vector{Any}
end

@inline get_handler(m::RouteMatch, method::Symbol) = get_handler(m.handlers, method)

"""
    Router — default `AbstractRouter` implementation.

    Supports: static paths, typed parameters (`:id::Int`), string parameters
    (`:slug`), and a catch-all wildcard (`*path`, must be the last segment).
"""
struct Router <: AbstractRouter
    fixed::Dict{String,FixedRoute}
    param_routes::Vector{ParamRoute}
    ws_routes::Dict{String,WsEndpoint}
    Router() = new(Dict{String,FixedRoute}(), ParamRoute[], Dict{String,WsEndpoint}())
end

@inline has_ws_routes(r::Router) = !isempty(r.ws_routes)
@inline ws_endpoint(r::Router, uri::String) = get(r.ws_routes, uri, nothing)

function route_count(r::Router)::AbstractString
    return string(length(r.fixed) + length(r.param_routes))
end

# --- Supported parameter types (extensible) ---

const VALID_METHODS = (:get, :post, :put, :patch, :delete, :options, :head)

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

Overlapping parametric routes resolve first-registered-first at dispatch;
static routes always take precedence over parametric ones.
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
    if path == "*"
        entry = get!(() -> FixedRoute(), router.fixed, "*")
        set_handler!(entry.handlers, method, handler)
        return
    end

    if !occursin(':', path) && !occursin('*', path)
        entry = get!(() -> FixedRoute(), router.fixed, path)
        set_handler!(entry.handlers, method, handler)
        return
    end

    segments = PatternSegment[]
    parts = collect(eachsplit(path, '/'; keepempty=false))
    for (idx, part) in enumerate(parts)
        if startswith(part, '*')
            idx == length(parts) ||
                throw(RouteError("Wildcard '*$part' must be the last route segment"))
            push!(segments, PatternSegment(String(part[2:end]), WildcardParam))
        elseif startswith(part, ':')
            name, T = _parse_param_spec(part[2:end])
            push!(segments, PatternSegment(name, T))
        else
            push!(segments, PatternSegment(part))
        end
    end

    route = findfirst(r -> r.segments == segments, router.param_routes)
    if route === nothing
        push!(router.param_routes, ParamRoute(segments, MethodMap()))
        set_handler!(router.param_routes[end].handlers, method, handler)
    else
        set_handler!(router.param_routes[route].handlers, method, handler)
    end
end

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

# --- Route Matching ---

"""
    _match_route(route, parts) → Union{Nothing,Vector{Any}}

Match a parametric route pattern against the split path segments. Returns
the captured parameters on success, `nothing` on failure.
"""
function _match_route(route::ParamRoute, parts::Vector{String})::Union{Nothing,Vector{Any}}
    n = length(parts)
    params = Any[]
    for (idx, seg) in enumerate(route.segments)
        if seg.is_param
            # Wildcard captures everything remaining (possibly empty).
            if seg.T === WildcardParam
                push!(params, join(parts[idx:end], "/"))
                return params
            end
            idx <= n || return nothing
            parsed = _try_parse_param(parts[idx], seg.T)
            parsed === nothing && return nothing
            push!(params, parsed)
        else
            idx <= n || return nothing
            parts[idx] == seg.text || return nothing
        end
    end
    n == length(route.segments) || return nothing
    return params
end

"""
    dispatch_route(router, method, path) → Union{Nothing, RouteMatch}

Find the matching route for the given method and path. Exact (static) matches
win; parametric routes are scanned in registration order; `"*"` catch-all is
the final fallback.
"""
function dispatch_route(router::Router, method::Symbol, path::AbstractString)::Union{Nothing,RouteMatch}
    clean = strip_query(path)

    # Fast path: exact match in the fixed-route table.
    fixed = get(router.fixed, clean, nothing)
    fixed !== nothing && return RouteMatch(fixed.handlers, ())

    # Parametric patterns (linear scan in registration order).
    if !isempty(router.param_routes)
        parts = String[String(seg) for seg in eachsplit(clean, '/'; keepempty=false)]
        for route in router.param_routes
            params = _match_route(route, parts)
            params === nothing || return RouteMatch(route.handlers, params)
        end
    end

    # Wildcard catch-all via "*" key in fixed routes.
    wildcard = get(router.fixed, "*", nothing)
    wildcard !== nothing && return RouteMatch(wildcard.handlers, ())

    return nothing
end

"""
    match_route_exact(router, method, path) → Union{Nothing, RouteMatch}

Match without the `"*"` fallback (used by static file serving to check route
ownership).
"""
function match_route_exact(router::Router, method::Symbol, path::AbstractString)::Union{Nothing,RouteMatch}
    clean = strip_query(path)
    fixed = get(router.fixed, clean, nothing)
    fixed !== nothing && return RouteMatch(fixed.handlers, ())
    if !isempty(router.param_routes)
        parts = String[String(seg) for seg in eachsplit(clean, '/'; keepempty=false)]
        for route in router.param_routes
            params = _match_route(route, parts)
            params === nothing || return RouteMatch(route.handlers, params)
        end
    end
    return nothing
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
# FastAPI-style DSL: get!(router, "/path", handler).

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
    n_dynamic = length(r.param_routes)
    n_ws = length(r.ws_routes)
    print(io, "Router(")
    print(io, n_fixed + n_dynamic, " route", (n_fixed + n_dynamic) == 1 ? "" : "s")
    n_ws > 0 && print(io, ", ", n_ws, " WebSocket", n_ws == 1 ? "" : "s")
    print(io, ")")
end