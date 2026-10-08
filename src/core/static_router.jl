"""
    StaticRouter — compile-time typed route table (trim-safe / AOT profile).

    Routes are declared with the [`@routes`](@ref) macro (or by constructing
    `StaticRoute`s directly). The whole table is a type: every path segment,
    capture type, method, and handler type is a type parameter, so dispatch is
    fully static — no runtime `apply_type`, no dynamic route lookup, no erased
    `Function` slots. This is the router profile that `juliac --trim=safe`
    accepts; the dynamic [`Router`](@ref) stays available for JIT use.

    ```julia
    router = @routes begin
        get("/hello", req -> text("hi"))
        get("/users/:id::Int", (req, id) -> json((id = id,)))
        get("/files/*path", (req, path) -> text(path))
    end
    app = App(router = router)
    ```

    Semantics match the dynamic `Router`: literal routes take precedence over
    patterns, patterns resolve in declaration order, a bare `"*"` route is the
    final fallback, and a path match with the wrong method answers `405` with
    the `Allow` set.
"""

# --- Path segment types (compile-time segment list) ---

"""Literal path segment, text as a `Symbol` type parameter."""
struct Lit{S} end

"""Captured parameter `:name::T` (name `N`, parsed type `T`)."""
struct Cap{N,T} end

"""Catch-all capture `*name` (captures the remaining path joined by `/`)."""
struct Wild{N} end

"""Bare `*` fallback: matches any path and captures nothing."""
struct CatchAll end

"""End of a path (no more segments)."""
struct PathEnd end

"""One path segment plus the rest of the path."""
struct PathCons{Seg,Rest} end

# --- Compile-time predicates (fold to constants per route) ---

@inline _is_fixed(::Type{PathEnd}) = true
@inline _is_fixed(::Type{PathCons{Lit{S},Rest}}) where {S,Rest} = _is_fixed(Rest)
@inline _is_fixed(::Type{PathCons{Seg,Rest}}) where {Seg,Rest} = false

@inline _is_catchall(::Type{PathCons{CatchAll,PathEnd}}) = true
@inline _is_catchall(::Type) = false

# --- Static route ---

"""
    StaticRoute{M,PT,F,MW} — one compile-time route.

    `M` is the method `Symbol`, `PT` the path type, `F` the handler type, `MW`
    the scoped middleware tuple type. `path` keeps the original literal for
    exact matching and display.
"""
struct StaticRoute{M,PT,F,MW}
    path::String
    handler::F
    middleware::MW
end

Base.show(io::IO, r::StaticRoute{M}) where {M} =
    print(io, "StaticRoute(", uppercase(String(M)), " ", r.path, ")")

@inline _route_method(::StaticRoute{M}) where {M} = M
@inline _route_is_fixed(route::StaticRoute{M,PT}) where {M,PT} = _is_fixed(PT)
@inline _route_is_catchall(route::StaticRoute{M,PT}) where {M,PT} = _is_catchall(PT)
@inline _route_is_pattern(route::StaticRoute) = !_route_is_fixed(route) && !_route_is_catchall(route)

@inline function _method_bit(m::Symbol)::UInt8
    m === :get     && return 0x01
    m === :post    && return 0x02
    m === :put     && return 0x04
    m === :delete  && return 0x08
    m === :patch   && return 0x10
    m === :options && return 0x20
    m === :head    && return 0x40
    throw(RouteError("Invalid HTTP method: $m"))
end

# --- Static router ---

"""
    StaticRouter{Routes<:Tuple} — the compiled route table.
"""
struct StaticRouter{Routes<:Tuple} <: AbstractRouter
    routes::Routes
end

StaticRouter(routes::StaticRoute...) = StaticRouter{typeof(routes)}(routes)

Base.length(r::StaticRouter)::Int = length(r.routes)
Base.isempty(r::StaticRouter)::Bool = isempty(r.routes)
Base.show(io::IO, r::StaticRouter) =
    print(io, "StaticRouter(", length(r.routes), " routes)")

freeze!(r::StaticRouter) = r
isfrozen(::StaticRouter) = true
haswsroutes(::StaticRouter) = false
getwsendpoint(::StaticRouter, uri::AbstractString) = nothing

route!(r::StaticRouter, method::Symbol, path::AbstractString, handler::Function; kwargs...) =
    throw(RouteError("static router: registration is closed (declare routes in @routes)"))
ws!(r::StaticRouter, path::AbstractString; kwargs...) =
    throw(RouteError("static router: WebSocket routes are not supported yet"))

# --- Path matching (unrolled over the path type) ---

@inline function _match_path(::Type{PathEnd}, parts::Vector{String}, i::Int)
    return i > length(parts) ? () : nothing
end

@inline function _match_path(::Type{PathCons{Lit{S},Rest}}, parts::Vector{String}, i::Int) where {S,Rest}
    (i <= length(parts) && parts[i] == String(S)) || return nothing
    return _match_path(Rest, parts, i + 1)
end

@inline function _match_path(::Type{PathCons{Cap{N,T},Rest}}, parts::Vector{String}, i::Int) where {N,T,Rest}
    i <= length(parts) || return nothing
    v = _try_parse_param(parts[i], T)
    v === nothing && return nothing
    rest = _match_path(Rest, parts, i + 1)
    rest === nothing && return nothing
    return (v, rest...)
end

@inline function _match_path(::Type{PathCons{Wild{N},PathEnd}}, parts::Vector{String}, i::Int) where {N}
    return (decode_path_segment(join(parts[i:end], "/")),)
end

@inline _match_path(::Type{PathCons{CatchAll,PathEnd}}, parts::Vector{String}, i::Int) = ()

@inline _match_route(route::StaticRoute{M,PT}, parts::Vector{String}) where {M,PT} =
    _match_path(PT, parts, 1)

@inline _split_parts(clean::AbstractString) =
    String[String(seg) for seg in eachsplit(clean, '/'; keepempty=false)]

const EMPTY_PARTS = String[]

# Whether the table has any pattern/catch-all route (folds to a constant, so a
# fixed-only router never splits the path).
@inline _has_patterns(::Tuple{}) = false
@inline function _has_patterns(routes::Tuple)
    _route_is_fixed(routes[1]) || return true
    return _has_patterns(Base.tail(routes))
end

@inline _parts_for(::Val{true}, clean::AbstractString) = _split_parts(clean)
@inline _parts_for(::Val{false}, clean::AbstractString) = EMPTY_PARTS

# --- Dispatch scans (recursive over the route tuple; `k` runs the match) ---

# Literal pass: exact path match, method check; a path hit shadows patterns.
@inline function _scan_fixed(::Tuple{}, method::Symbol, clean, parts, mask::UInt8, k)
    return (nothing, false, mask)
end

@inline function _scan_fixed(routes::Tuple, method::Symbol, clean, parts, mask::UInt8, k)
    route = routes[1]
    rest = Base.tail(routes)
    if _route_is_fixed(route)
        if clean == route.path
            method === _route_method(route) && return (k(route, ()), true, mask)
            return _scan_fixed(rest, method, clean, parts, mask | _method_bit(_route_method(route)), k)
        end
    end
    return _scan_fixed(rest, method, clean, parts, mask, k)
end

# Pattern pass: first pattern whose path matches wins (declaration order).
@inline function _scan_pattern(::Tuple{}, method::Symbol, parts, mask::UInt8, k)
    return (nothing, mask)
end

@inline function _scan_pattern(routes::Tuple, method::Symbol, parts, mask::UInt8, k)
    route = routes[1]
    rest = Base.tail(routes)
    if _route_is_pattern(route)
        params = _match_route(route, parts)
        if params !== nothing
            method === _route_method(route) && return (k(route, params), mask)
            return (nothing, mask | _method_bit(_route_method(route)))
        end
    end
    return _scan_pattern(rest, method, parts, mask, k)
end

# Catch-all pass: bare `"*"` routes, declaration order.
@inline function _scan_catchall(::Tuple{}, method::Symbol, parts, mask::UInt8, k)
    return (nothing, mask)
end

@inline function _scan_catchall(routes::Tuple, method::Symbol, parts, mask::UInt8, k)
    route = routes[1]
    rest = Base.tail(routes)
    if _route_is_catchall(route)
        if method === _route_method(route)
            return (k(route, ()), mask)
        end
        return _scan_catchall(rest, method, parts, mask | _method_bit(_route_method(route)), k)
    end
    return _scan_catchall(rest, method, parts, mask, k)
end

# --- Handler invocation (typed params, no erased callable) ---

@inline _handler_terminal(f::F, ::Tuple{}) where {F} = req -> f(req)
@inline _handler_terminal(f::F, params::Tuple) where {F} = req -> f(req, params...)

@inline function _invoke_static(route::StaticRoute, ctx::RequestContext, req::Request, params)
    terminal = _handler_terminal(route.handler, params)
    return format_response(runpipeline(ctx.middlewares, route.middleware, req, terminal))
end

struct NotFoundTerminal end
(t::NotFoundTerminal)(r::Request) = Response(Plain, "404 Not Found"; status=404)

struct MethodNotAllowedTerminal
    mask::UInt8
end
(t::MethodNotAllowedTerminal)(r::Request) = _method_not_allowed(t.mask)

@inline function _fallback_static(ctx::RequestContext, req::Request, mask::UInt8)
    terminal = mask == 0x00 ? NotFoundTerminal() : MethodNotAllowedTerminal(mask)
    return format_response(runpipeline(ctx.middlewares, (), req, terminal))
end

function _dispatch_static(router::StaticRouter, ctx::RequestContext, req::Request)
    method = _normalize_method(req.method)
    clean = stripquery(req.uri)
    parts = _parts_for(Val(_has_patterns(router.routes)), clean)
    k = (route, params) -> _invoke_static(route, ctx, req, params)

    res, fixed_hit, mask = _scan_fixed(router.routes, method, clean, parts, UInt8(0), k)
    res === nothing || return res
    fixed_hit && return _fallback_static(ctx, req, mask)

    res, mask = _scan_pattern(router.routes, method, parts, mask, k)
    res === nothing || return res
    mask != 0x00 && return _fallback_static(ctx, req, mask)

    res, mask = _scan_catchall(router.routes, method, parts, UInt8(0), k)
    res === nothing || return res
    return _fallback_static(ctx, req, mask)
end

# --- AbstractRouter protocol (for direct/plug-in use) ---

@inline function _matched_result(route::StaticRoute{M,PT,F,MW}, params) where {M,PT,F,MW}
    ep = Endpoint{F,MW}(route.handler, route.middleware, nothing)
    return Matched(ep, SingleEndpoint(ep, M), params)
end

function matchroute(router::StaticRouter, method::Symbol, path::AbstractString)::RouteResult
    m = _normalize_method(method)
    clean = stripquery(path)
    parts = _parts_for(Val(_has_patterns(router.routes)), clean)
    k = (route, params) -> _matched_result(route, params)

    res, fixed_hit, mask = _scan_fixed(router.routes, m, clean, parts, UInt8(0), k)
    res === nothing || return res
    fixed_hit && return MethodMismatch(mask)

    res, mask = _scan_pattern(router.routes, m, parts, mask, k)
    res === nothing || return res
    mask != 0x00 && return MethodMismatch(mask)

    res, mask = _scan_catchall(router.routes, m, parts, UInt8(0), k)
    res === nothing || return res
    mask != 0x00 && return MethodMismatch(mask)
    return NoMatch()
end

function hasroute(router::StaticRouter, path::AbstractString)::Bool
    clean = stripquery(path)
    parts = _parts_for(Val(_has_patterns(router.routes)), clean)
    return _has_route(router.routes, clean, parts)
end

@inline _has_route(::Tuple{}, clean, parts) = false
@inline function _has_route(routes::Tuple, clean, parts)
    route = routes[1]
    hit = if _route_is_fixed(route)
        clean == route.path
    elseif _route_is_catchall(route)
        false
    else
        _match_route(route, parts) !== nothing
    end
    hit && return true
    return _has_route(Base.tail(routes), clean, parts)
end

# --- Trim-safe process specialization (CPS dispatch, no RouteResult union) ---

function process(ctx::RequestContext{<:StaticRouter}, request::Request)
    request.services = ctx.services
    return _guarded_process(ctx, request) do
        _dispatch_static(ctx.router, ctx, request)
    end
end

# --- @routes macro ---

const _ROUTER_METHODS = (:get, :post, :put, :patch, :delete, :options, :head)

function _path_type_expr(path::AbstractString)
    expr = :PathEnd
    parts = collect(eachsplit(path, '/'; keepempty=false))
    for idx in length(parts):-1:1
        part = parts[idx]
        if startswith(part, '*')
            idx == length(parts) ||
                error("@routes: wildcard must be the last segment in '$path'")
            name = String(part[2:end])
            if isempty(name)
                expr = :(PathCons{CatchAll,$expr})
            else
                expr = :(PathCons{Wild{$(QuoteNode(Symbol(name)))},$expr})
            end
        elseif startswith(part, ':')
            spec = part[2:end]
            sep = findfirst("::", spec)
            if sep === nothing
                name = spec
                T = String
            else
                name = spec[1:first(sep)-1]
                tname = spec[last(sep)+1:end]
                T = get(PARAM_TYPES, tname, String)
            end
            isempty(name) && error("@routes: parameter name is empty in '$path'")
            expr = :(PathCons{Cap{$(QuoteNode(Symbol(name))),$T},$expr})
        else
            expr = :(PathCons{Lit{$(QuoteNode(Symbol(part)))},$expr})
        end
    end
    return expr
end

function _route_expr(ex::Expr)
    ex.head === :call || error("@routes: expected `method(\"path\", handler)`, got $ex")
    fname = ex.args[1]
    fname isa Symbol && fname in _ROUTER_METHODS ||
        error("@routes: unknown method `$fname` (expected one of $(_ROUTER_METHODS))")
    args = ex.args[2:end]
    mw_expr = :(nothing)
    if !isempty(args) && args[1] isa Expr && args[1].head === :parameters
        for kw in args[1].args
            (kw isa Expr && kw.head === :kw && kw.args[1] === :middleware) ||
                error("@routes: only the `middleware` keyword is supported")
            mw_expr = kw.args[2]
        end
        args = args[2:end]
    end
    length(args) == 2 || error("@routes: expected `method(\"path\", handler)`")
    path, handler = args
    path isa String || error("@routes: path must be a string literal")
    pathtype = _path_type_expr(path)
    return quote
        let h = $(esc(handler)), mw = asmiddlewaretuple($(esc(mw_expr)))
            StaticRoute{$(QuoteNode(fname)),$pathtype,typeof(h),typeof(mw)}($path, h, mw)
        end
    end
end

"""
    @routes begin
        get("/hello", req -> text("hi"))
        get("/users/:id::Int", (req, id) -> json((id = id,)))
        get("/files/*path", (req, path) -> text(path))
        post("/echo", req -> text(body(req)); middleware=(cors(),))
    end

Build a [`StaticRouter`](@ref) from a block of route declarations. Paths are
parsed at macro-expansion time: `:name` captures a decoded `String`,
`:name::T` captures a parsed `T` (Int, Float64, Bool, …), `*name` captures the
rest of the path, and a bare `"*"` is the final fallback.
"""
macro routes(block)
    block isa Expr && block.head === :block ||
        error("@routes expects a `begin ... end` block of route declarations")
    routes = Any[]
    for ex in block.args
        ex isa LineNumberNode && continue
        push!(routes, _route_expr(ex))
    end
    return :(StaticRouter($(routes...)))
end
