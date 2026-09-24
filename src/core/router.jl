"""
    Default HTTP + WebSocket router.

    Design goals: simple, readable, and easy to replace. Dispatch is:
    - O(1) exact lookup in a `Dict` of fixed routes (no dynamic segments),
    - a registration-ordered linear scan of parametric route patterns
      (`:name::Type` and `*wildcard` segments),
    - a `"*"` catch-all fallback registered in the fixed table.

    Exact (static) matches always win; overlapping parametric routes resolve
    in registration order. Parameters are returned as *typed tuples*, so a
    matched route carries its concrete parameter types (`Matched{<:Tuple}`)
    and handlers splat a statically-known arity when the call is specialized.

    The router never interprets handlers, middleware, or metadata: each route
    owns an `Endpoint`, and the runtime composes global + scoped middleware.

    Implementers wanting a different strategy should subtype `AbstractRouter`
    and implement the protocol in `router/interface.jl`.
"""

# --- Route endpoint (handler + scoped middleware + metadata) ---

"""
    Endpoint{F} — what a route owns: handler, scoped middleware, and metadata.

    The handler's concrete type is a type parameter, so the endpoint can be
    invoked without a dynamic call when its type is known (custom routers,
    compiled terminals); registration specializes on the handler type.

    The router only stores and returns `Endpoint`s; it does not execute
    middleware. `middleware` applies to this route (in addition to app-global
    middleware); `metadata` is opaque and available for OpenAPI-style docs.
"""
struct Endpoint{F,M<:Tuple}
    handler::F
    middleware::M
    metadata::Any
end

function Endpoint(handler::F;
                  middleware=nothing,
                  metadata=nothing) where {F}
    mws = asmiddlewaretuple(middleware)
    return Endpoint{F,typeof(mws)}(handler, mws, metadata)
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

# Explicit per-method branches instead of `getfield(mm, symbol)`: the compiler
# sees every field directly (no dynamic field lookup) and each branch is
# type-stable. Invalid methods still fail loudly.
"""
    getendpoint(mm, method) → Union{Nothing, Endpoint}

The endpoint registered for `method`, or `nothing`; throws `RouteError` for a
method outside the seven supported HTTP methods.
"""
@inline function getendpoint(mm::MethodMap, method::Symbol)::Union{Nothing,Endpoint}
    method === :get     && return mm.get
    method === :post    && return mm.post
    method === :put     && return mm.put
    method === :delete  && return mm.delete
    method === :patch   && return mm.patch
    method === :options && return mm.options
    method === :head    && return mm.head
    throw(RouteError("Invalid HTTP method: $method"))
end

"""
    gethandler(mm, method) → Union{Nothing, Function}
"""
@inline function gethandler(mm::MethodMap, method::Symbol)::Union{Nothing,Function}
    ep = getendpoint(mm, method)
    return ep === nothing ? nothing : ep.handler
end

function sethandler!(mm::MethodMap, method::Symbol, ep::Endpoint)
    method === :get     ? (mm.get     = ep) :
    method === :post    ? (mm.post    = ep) :
    method === :put     ? (mm.put     = ep) :
    method === :delete  ? (mm.delete  = ep) :
    method === :patch   ? (mm.patch   = ep) :
    method === :options ? (mm.options = ep) :
    method === :head    ? (mm.head    = ep) :
    throw(RouteError("Invalid HTTP method: $method"))
    return
end

@inline sethandler!(mm::MethodMap, method::Symbol, handler::Function) =
    sethandler!(mm, method, Endpoint(handler))

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

"""
    AbstractCompiledDispatch — opaque handle to a frozen router's compiled table.

    `freeze!(router)` builds a `CompiledDispatch` (see `compiled.jl`) that
    pre-bakes per-route terminals and matches parametric routes through a
    statically-typed chain. The field stays abstract so `Router` never depends
    on the compiled types; dispatch reaches the concrete table via method
    dispatch on this handle.
"""
abstract type AbstractCompiledDispatch end

"""
    Router — default `AbstractRouter` implementation.

    Supports: static paths, typed parameters (`:id::Int`), string parameters
    (`:slug`), and a catch-all wildcard (`*path`, must be the last segment).
    `freeze!` closes the route table (registration throws afterwards) and
    compiles the closed table into a `CompiledDispatch` — the contract that
    makes the router amenable to AOT/`--trim=safe` builds.
"""
mutable struct Router <: AbstractRouter
    fixed::Dict{String,FixedRoute}
    param_routes::Vector{ParamRoute}
    ws_routes::Dict{String,WSEndpoint}
    frozen::Bool
    compiled::Union{Nothing,AbstractCompiledDispatch}
    Router() = new(Dict{String,FixedRoute}(), ParamRoute[],
                   Dict{String,WSEndpoint}(), false, nothing)
end

"""
    freeze!(router) → router

Close the route table: any later `route!`/`ws!` throws `RouteError`. Dispatch
keeps working. This is the closed-route contract required by AOT/`--trim=safe`
profiles (a static route table can be compiled once and pruned).

Freezing also **compiles** the closed table into a `CompiledDispatch` (see
`compiled.jl`): each fixed route and parametric route gets a pre-baked
terminal (handler + scoped middleware fused, with the handler's concrete type
captured), and parametric matching runs through a statically-typed chain with
no per-request path splitting. The pipeline uses the compiled path via
`terminalfor` when `compiled !== nothing`; `matchroute` keeps its
generic (correct) implementation.
"""
function freeze!(r::Router)
    r.frozen && return r
    r.frozen = true
    r.compiled = _compile!(r)
    return r
end

"""
    isfrozen(router) → Bool

Whether `freeze!` has been called on this router (registration closed; the
table compiled). Custom `AbstractRouter`s default to `false`.
"""
@inline isfrozen(r::Router) = r.frozen

@inline haswsroutes(r::Router) = !isempty(r.ws_routes)
@inline getwsendpoint(r::Router, uri::String) = get(r.ws_routes, uri, nothing)

Base.length(r::Router)::Int = length(r.fixed) + length(r.param_routes)

# --- Supported parameter types (extensible) ---

const VALID_METHODS = (:get, :post, :put, :patch, :delete, :options, :head)

const PARAM_TYPES = Dict{String,Type}(
    "String" => String, "Int" => Int, "Int64" => Int64, "Int32" => Int32,
    "Float64" => Float64, "Float32" => Float32, "Bool" => Bool,
    "UInt" => UInt, "UInt64" => UInt64
)

# --- Route Registration ---

"""
    route!(router, method, path, handler; middleware=nothing, metadata=nothing) → router

Register an HTTP route. Supports:
- Static: `/health`
- Typed params: `/users/:id::Int`
- String params: `/posts/:slug`
- Wildcard: `/*path` (must be last segment)

`middleware` is scoped to this route (composed with app-global middleware at
dispatch time); it accepts `nothing`, a single middleware/callable, or a
vector/tuple of them. `metadata` is opaque and available for future
OpenAPI-style tooling.

Overlapping parametric routes resolve first-registered-first at dispatch;
static routes always take precedence over parametric ones.
"""
function route!(router::Router, method::Symbol, path::AbstractString, handler::Function;
                middleware=nothing,
                metadata=nothing)
    m = _normalize_method(method)
    router.frozen && throw(RouteError("router is frozen: registration is closed"))
    _register_route!(router, m, String(path),
                     Endpoint(handler; middleware=middleware, metadata=metadata))
    return router
end

function route!(router::Router, method::AbstractString, path::AbstractString, handler::Function;
                middleware=nothing,
                metadata=nothing)
    route!(router, _normalize_method(Symbol(method)), path, handler;
           middleware=middleware, metadata=metadata)
end

# Registration is cold: accept `:GET`/`:Get` by lowering once. Valid lowercase
# methods (the hot-path protocol form) pass through the tuple scan untouched.
@inline function _normalize_method(method::Symbol)::Symbol
    method in VALID_METHODS && return method
    lowered = Symbol(lowercase(String(method)))
    lowered in VALID_METHODS || throw(RouteError("Invalid HTTP method: $method"))
    return lowered
end

function _register_route!(router::Router, method::Symbol, path::String, endpoint::Endpoint)
    if path == "*"
        entry = get!(() -> FixedRoute(), router.fixed, "*")
        sethandler!(entry.handlers, method, endpoint)
        return
    end

    if !occursin(':', path) && !occursin('*', path)
        entry = get!(() -> FixedRoute(), router.fixed, path)
        sethandler!(entry.handlers, method, endpoint)
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
        sethandler!(router.param_routes[end].handlers, method, endpoint)
    else
        sethandler!(router.param_routes[route].handlers, method, endpoint)
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

# Path segments are URL-decoded before parsing (RFC 3986): `+` stays a literal
# plus in paths, unlike query strings.
@inline function _try_parse_param(value::AbstractString, ::Type{String})::String
    return decode_path_segment(String(value))
end

@inline function _try_parse_param(value::AbstractString, ::Type{T})::Union{Nothing,T} where {T}
    return tryparse(T, decode_path_segment(String(value)))
end

# --- Typed parameter extraction ---

@inline _extract(::Tuple{}, ::Tuple{}, ::Vector{String}) = ()

function _extract(types::Tuple, pos::Tuple, parts::Vector{String})
    T = types[1]
    i = pos[1]
    v = if T === WildcardParam
        decode_path_segment(join(parts[i:end], "/"))
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
    _matchroute(route, parts) → Union{Nothing, <:Tuple}

Match a parametric route pattern against the split path segments. Returns the
captured parameters as a typed tuple on success, `nothing` on failure.
"""
function _matchroute(route::ParamRoute{P,N}, parts::Vector{String}) where {P,N}
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
    matchroute(router, method, path) → RouteResult

Resolve a request to its exhaustive outcome: `Matched(endpoint, handlers,
params)` when the route serves the method, `NoMatch` when the path matches
nothing, or `NotAllowed{allowed}` carrying the route's method bitmask.
Exact (static) matches win; parametric routes are scanned in registration
order; the `"*"` catch-all is the final fallback. `HEAD` is served only by an
explicit `head!` route — there is no auto-HEAD fallback.
"""
function matchroute(router::Router, method::Symbol, path::AbstractString)::RouteResult
    m = _normalize_method(method)
    clean = stripquery(path)
    found = _find_route(router, clean)
    found === nothing && return NoMatch()
    mm, params = found
    ep = resolve_method(mm, m)
    ep === nothing && return NotAllowed(method_bitmask(mm))
    return Matched(ep, mm, params)
end

"""
    hasroute(router, path) → Bool

`true` when a concrete (non-catch-all) route owns the path, regardless of
method — used by static file serving to avoid shadowing registered routes
(the previous `match_route_exact` semantic).
"""
function hasroute(router::Router, path::AbstractString)::Bool
    clean = stripquery(path)
    return _find_route_no_wildcard(router, clean) !== nothing
end

# --- RouteResult helpers ---

# Method bitmask: GET=1, POST=2, PUT=4, DELETE=8, PATCH=16, OPTIONS=32, HEAD=64.
# `HEAD` is included only when an explicit `head!` route exists (no auto-HEAD
# fallback), so `Allow` reflects exactly what the route serves.
@inline function method_bitmask(mm::MethodMap)::UInt8
    mask = UInt8(0)
    mm.get     === nothing || (mask |= 0x01)
    mm.post    === nothing || (mask |= 0x02)
    mm.put     === nothing || (mask |= 0x04)
    mm.delete  === nothing || (mask |= 0x08)
    mm.patch   === nothing || (mask |= 0x10)
    mm.options === nothing || (mask |= 0x20)
    mm.head    === nothing || (mask |= 0x40)
    return mask
end

# Serialize the bitmask as the RFC 9110 §15.5.6 Allow header value.
@inline function allow_from_bitmask(mask::UInt8)::String
    allow = String[]
    (mask & 0x01) != 0 && push!(allow, "GET")
    (mask & 0x02) != 0 && push!(allow, "POST")
    (mask & 0x04) != 0 && push!(allow, "PUT")
    (mask & 0x08) != 0 && push!(allow, "DELETE")
    (mask & 0x10) != 0 && push!(allow, "PATCH")
    (mask & 0x20) != 0 && push!(allow, "OPTIONS")
    (mask & 0x40) != 0 && push!(allow, "HEAD")
    return join(allow, ", ")
end

# Resolve a method against a route's MethodMap. No auto-HEAD fallback: HEAD is
# served only by an explicit `head!` endpoint.
@inline function resolve_method(mm::MethodMap, method::Symbol)
    return getendpoint(mm, method)
end

@inline function _first_endpoint(mm::MethodMap)
    mm.get     !== nothing && return mm.get
    mm.post    !== nothing && return mm.post
    mm.put     !== nothing && return mm.put
    mm.delete  !== nothing && return mm.delete
    mm.patch   !== nothing && return mm.patch
    mm.options !== nothing && return mm.options
    mm.head    !== nothing && return mm.head
    return nothing
end

# Path-only lookup (includes the "*" catch-all): (handlers, params) or nothing.
@inline function _find_route(router::Router, clean::AbstractString)
    fixed = get(router.fixed, clean, nothing)
    fixed !== nothing && return (fixed.handlers, ())
    if !isempty(router.param_routes)
        parts = String[String(seg) for seg in eachsplit(clean, '/'; keepempty=false)]
        for route in router.param_routes
            params = _matchroute(route, parts)
            params === nothing || return (route.handlers, params)
        end
    end
    wildcard = get(router.fixed, "*", nothing)
    wildcard !== nothing && return (wildcard.handlers, ())
    return nothing
end

@inline function _find_route_no_wildcard(router::Router, clean::AbstractString)
    fixed = get(router.fixed, clean, nothing)
    fixed !== nothing && return (fixed.handlers, ())
    if !isempty(router.param_routes)
        parts = String[String(seg) for seg in eachsplit(clean, '/'; keepempty=false)]
        for route in router.param_routes
            params = _matchroute(route, parts)
            params === nothing || return (route.handlers, params)
        end
    end
    return nothing
end

# --- WebSocket Registration ---

function ws!(router::Router, path::AbstractString;
             on_message::Function,
             on_open::Union{Function,Nothing}=nothing,
             on_close::Union{Function,Nothing}=nothing,
             allowed_origins=nothing)
    router.frozen && throw(RouteError("router is frozen: registration is closed"))
    router.ws_routes[String(path)] = WSEndpoint(on_message=on_message, on_open=on_open,
        on_close=on_close, allowed_origins=asstrings(allowed_origins))
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
function Base.get!(r::Router, path::AbstractString, handler::Function)
    route!(r, :get, path, handler); return r
end
Base.get!(f::Function, r::Router, path::AbstractString) = Base.get!(r, path, f)

"""
    post!(router_or_app, path, handler)
"""
function post!(r::Router, path::AbstractString, handler::Function)
    route!(r, :post, path, handler); return r
end
post!(f::Function, r::Router, path::AbstractString) = post!(r, path, f)

"""
    put!(router_or_app, path, handler)
"""
function Base.put!(r::Router, path::AbstractString, handler::Function)
    route!(r, :put, path, handler); return r
end
Base.put!(f::Function, r::Router, path::AbstractString) = Base.put!(r, path, f)

"""
    patch!(router_or_app, path, handler)
"""
function patch!(r::Router, path::AbstractString, handler::Function)
    route!(r, :patch, path, handler); return r
end
patch!(f::Function, r::Router, path::AbstractString) = patch!(r, path, f)

"""
    delete!(router_or_app, path, handler)
"""
function Base.delete!(r::Router, path::AbstractString, handler::Function)
    route!(r, :delete, path, handler); return r
end
Base.delete!(f::Function, r::Router, path::AbstractString) = Base.delete!(r, path, f)

"""
    options!(router_or_app, path, handler)
"""
function options!(r::Router, path::AbstractString, handler::Function)
    route!(r, :options, path, handler); return r
end
options!(f::Function, r::Router, path::AbstractString) = options!(r, path, f)

"""
    head!(router_or_app, path, handler)
"""
function head!(r::Router, path::AbstractString, handler::Function)
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
