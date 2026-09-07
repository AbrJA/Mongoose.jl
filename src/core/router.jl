"""
    Default HTTP + WebSocket router.

    Design goals: simple, readable, and easy to replace. Dispatch is:
    - O(1) exact lookup in a `Dict` of fixed routes (no dynamic segments),
    - a registration-ordered linear scan of parametric route patterns
      (`:name::Type` and `*wildcard` segments),
    - a `"*"` catch-all fallback registered in the fixed table.

    Exact (static) matches always win; overlapping parametric routes resolve
    in registration order. Parameters are returned as *typed tuples*, so a
    matched route carries its concrete parameter types (`RouteMatch{<:Tuple}`)
    and handlers splat a statically-known arity when the call is specialized.

    The router never interprets handlers, middleware, or metadata: each route
    owns an `Endpoint`, and the runtime composes global + scoped middleware.

    Implementers wanting a different strategy should subtype `AbstractRouter`
    and implement the protocol in `router/interface.jl`.
"""

# --- Route endpoint (handler + scoped middleware + metadata) ---

"""
    Endpoint — what a route owns: handler, scoped middleware, and metadata.

    The router only stores and returns `Endpoint`s; it does not execute
    middleware. `middleware` applies to this route (in addition to app-global
    middleware); `metadata` is opaque and available for OpenAPI-style docs.
"""
struct Endpoint
    handler::Function
    middleware::Vector{AbstractMiddleware}
    metadata::Any
end

function Endpoint(handler::Function;
                  middleware::AbstractVector=AbstractMiddleware[],
                  metadata=nothing)
    mws = AbstractMiddleware[as_middleware(m) for m in middleware]
    return Endpoint(handler, mws, metadata)
end

# --- Method Dispatch (struct fields instead of Dict for zero-allocation dispatch) ---

"""
    MethodMap — Fixed-slot storage for HTTP method → endpoint mapping.
"""
mutable struct MethodMap
    get::Union{Nothing,Endpoint}
    post::Union{Nothing,Endpoint}
    put::Union{Nothing,Endpoint}
    delete::Union{Nothing,Endpoint}
    patch::Union{Nothing,Endpoint}
    options::Union{Nothing,Endpoint}
    head::Union{Nothing,Endpoint}
    MethodMap() = new(nothing, nothing, nothing, nothing, nothing, nothing, nothing)
end

@inline function _method_slot(mm::MethodMap, method::Symbol)::Symbol
    method === :get     && return :get
    method === :post    && return :post
    method === :put     && return :put
    method === :delete  && return :delete
    method === :patch   && return :patch
    method === :options && return :options
    method === :head    && return :head
    throw(RouteError("Invalid HTTP method: $method"))
end

"""
    get_endpoint(mm, method) → Union{Nothing, Endpoint}
"""
@inline function get_endpoint(mm::MethodMap, method::Symbol)::Union{Nothing,Endpoint}
    return getfield(mm, _method_slot(mm, method))
end

"""
    get_handler(mm, method) → Union{Nothing, Function}
"""
@inline function get_handler(mm::MethodMap, method::Symbol)::Union{Nothing,Function}
    ep = getfield(mm, _method_slot(mm, method))
    return ep === nothing ? nothing : ep.handler
end

function set_handler!(mm::MethodMap, method::Symbol, ep::Endpoint)
    setfield!(mm, _method_slot(mm, method), ep)
    return
end

@inline set_handler!(mm::MethodMap, method::Symbol, handler::Function) =
    set_handler!(mm, method, Endpoint(handler))

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

    Parameter positions and their types are stored as concrete tuples so that
    matched parameters come back as a statically-typed `Tuple` (no `Any`
    boxing, and a splat with compile-time arity when dispatch is specialized).
"""
struct ParamRoute{P<:Tuple,N}
    segments::Vector{PatternSegment}
    handlers::MethodMap
    is_wildcard::Bool              # last segment is a `*` catch-all
    param_pos::NTuple{N,Int}       # segment indices that capture parameters
    param_types::P                 # e.g. (Int, String)
end

# --- Route Match Result ---

"""
    RouteMatch — result of a successful `dispatch_route`.

    `params` carries the captured path parameters. Fixed routes yield an empty
    tuple (zero allocation); parametric routes yield a typed tuple such as
    `Tuple{Int}` or `Tuple{Int,String}`.
"""
struct RouteMatch{P}
    handlers::MethodMap
    params::P
end

@inline get_handler(m::RouteMatch, method::Symbol) = get_handler(m.handlers, method)
@inline get_endpoint(m::RouteMatch, method::Symbol) = get_endpoint(m.handlers, method)

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
    route!(router, method, path, handler; middleware=[], metadata=nothing) → router

Register an HTTP route. Supports:
- Static: `/health`
- Typed params: `/users/:id::Int`
- String params: `/posts/:slug`
- Wildcard: `/*path` (must be last segment)

`middleware` is scoped to this route (composed with app-global middleware at
dispatch time); `metadata` is opaque and available for future OpenAPI-style
tooling.

Overlapping parametric routes resolve first-registered-first at dispatch;
static routes always take precedence over parametric ones.
"""
function route!(router::Router, method::Symbol, path::AbstractString, @nospecialize(handler::Function);
                middleware::AbstractVector=AbstractMiddleware[],
                metadata=nothing)
    method in VALID_METHODS || throw(RouteError("Invalid HTTP method: $method"))
    _register_route!(router, method, String(path),
                     Endpoint(handler; middleware=middleware, metadata=metadata))
    return router
end

function route!(router::Router, method::AbstractString, path::AbstractString, @nospecialize(handler::Function);
                middleware::AbstractVector=AbstractMiddleware[],
                metadata=nothing)
    route!(router, Symbol(lowercase(method)), path, handler;
           middleware=middleware, metadata=metadata)
end

function _register_route!(router::Router, method::Symbol, path::String, endpoint::Endpoint)
    if path == "*"
        entry = get!(() -> FixedRoute(), router.fixed, "*")
        set_handler!(entry.handlers, method, endpoint)
        return
    end

    if !occursin(':', path) && !occursin('*', path)
        entry = get!(() -> FixedRoute(), router.fixed, path)
        set_handler!(entry.handlers, method, endpoint)
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

    pos = Int[]
    types = Type[]
    for (i, seg) in enumerate(segments)
        seg.is_param || continue
        push!(pos, i)
        push!(types, seg.T)
    end
    is_wildcard = !isempty(types) && types[end] === WildcardParam

    route = findfirst(r -> r.segments == segments, router.param_routes)
    if route === nothing
        param_route = ParamRoute(segments, MethodMap(), is_wildcard,
                                 (pos...,), (types...,))
        push!(router.param_routes, param_route)
        set_handler!(router.param_routes[end].handlers, method, endpoint)
    else
        set_handler!(router.param_routes[route].handlers, method, endpoint)
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

# --- Typed parameter extraction ---

@inline _extract(::Tuple{}, ::Tuple{}, ::Vector{String}) = ()

function _extract(types::Tuple, pos::Tuple, parts::Vector{String})
    T = types[1]
    i = pos[1]
    v = if T === WildcardParam
        join(parts[i:end], "/")
    else
        _try_parse_param(parts[i], T)
    end
    v === nothing && return nothing
    rest = _extract(Base.tail(types), Base.tail(pos), parts)
    rest === nothing && return nothing
    return (v, rest...)
end

# --- Route Matching ---

"""
    _match_route(route, parts) → Union{Nothing, <:Tuple}

Match a parametric route pattern against the split path segments. Returns the
captured parameters as a typed tuple on success, `nothing` on failure.
"""
function _match_route(route::ParamRoute{P,N}, parts::Vector{String}) where {P,N}
    nseg = length(route.segments)
    n = length(parts)
    if route.is_wildcard
        n < nseg - 1 && return nothing
    elseif n != nseg
        return nothing
    end

    @inbounds for idx in 1:nseg
        seg = route.segments[idx]
        if !seg.is_param
            parts[idx] == seg.text || return nothing
        end
    end
    return _extract(route.param_types, route.param_pos, parts)
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