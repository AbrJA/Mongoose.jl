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
    final fallback, a path match with the wrong method answers `405` with the
    `Allow` set, and a typed capture that fails to parse (`/users/abraham`
    against `/users/:id::Int`) answers `400` unless another route serves the
    path.
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

"""A typed capture failed to parse (the 400 signal), unlike `nothing` (no structural match)."""
struct ParamParseFail end

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

@inline _route_is_fixed(route::StaticRoute{M,PT}) where {M,PT} = _is_fixed(PT)
@inline _route_is_catchall(route::StaticRoute{M,PT}) where {M,PT} = _is_catchall(PT)

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
    StaticWSRoute{M,O,C} — one compile-time WebSocket endpoint.

    Exact-path route: the transport matches `path` and calls `on_message` /
    `on_open` / `on_close` through their concrete types (no dynamic lookup).
"""
struct StaticWSRoute{M,O,C}
    path::String
    on_message::M
    on_open::O
    on_close::C
    allowed_origins::Vector{String}
end

function StaticWSRoute(path::AbstractString; on_message::M, on_open::O=nothing,
                       on_close::C=nothing, allowed_origins=nothing) where {M,O,C}
    return StaticWSRoute{M,O,C}(String(path), on_message, on_open, on_close,
                                asstrings(allowed_origins))
end

"""
    StaticRouter{Routes<:Tuple,WSRoutes<:Tuple} — the compiled route table.

    `Routes` holds the HTTP routes; `WSRoutes` the WebSocket endpoints
    (declared with `ws(...)` in `@routes`).
"""
struct StaticRouter{Routes<:Tuple,WSRoutes<:Tuple} <: AbstractRouter
    routes::Routes
    ws_routes::WSRoutes
end

StaticRouter(routes::StaticRoute...) = StaticRouter{typeof(routes),Tuple{}}(routes, ())

Base.length(r::StaticRouter)::Int = length(r.routes)
Base.isempty(r::StaticRouter)::Bool = isempty(r.routes)
Base.show(io::IO, r::StaticRouter) =
    print(io, "StaticRouter(", length(r.routes), " routes",
          isempty(r.ws_routes) ? "" : ", $(length(r.ws_routes)) ws", ")")

freeze!(r::StaticRouter) = r
isfrozen(::StaticRouter) = true
haswsroutes(::StaticRouter{R,W}) where {R,W} = W !== Tuple{}
getwsendpoint(::StaticRouter, uri::AbstractString) = nothing

route!(r::StaticRouter, method::Symbol, path::AbstractString, handler::Function; kwargs...) =
    throw(RouteError("static router: registration is closed (declare routes in @routes)"))
ws!(r::StaticRouter, path::AbstractString; kwargs...) =
    throw(RouteError("static router: declare WebSocket routes with ws(...) in @routes"))

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
    # Structural continuation first: a failed capture is only a 400 signal when
    # the rest of the pattern structurally matches (`/users/abraham` against
    # `/users/:id::Int/posts` is a 404 — the trailing segment is missing).
    rest = _match_path(Rest, parts, i + 1)
    rest === nothing && return nothing
    rest isa ParamParseFail && return ParamParseFail
    v === nothing && return ParamParseFail()
    return (v, rest...)
end

@inline function _match_path(::Type{PathCons{Wild{N},PathEnd}}, parts::Vector{String}, i::Int) where {N}
    return (decode_path_segment(join(parts[i:end], "/")),)
end

@inline _match_path(::Type{PathCons{CatchAll,PathEnd}}, parts::Vector{String}, i::Int) = ()

@inline function _match_route(route::StaticRoute{M,PT}, parts::Vector{String}) where {M,PT}
    m = _match_path(PT, parts, 1)
    return m isa ParamParseFail ? nothing : m
end

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

# --- Dispatch scans (generated flat over the route tuple; `k` runs the match) ---
# Flat per-route branches: recursive @inline scans explode compile memory.

# Literal pass: exact path match, method check; a path hit shadows patterns.
@generated function _scan_fixed(routes::Routes, method::Symbol, clean, parts,
                                mask::UInt8, k) where {Routes<:Tuple}
    exprs = Any[]
    for i in 1:length(Routes.parameters)
        RT = Routes.parameters[i]
        _is_fixed(RT.parameters[2]) || continue
        M = RT.parameters[1]
        push!(exprs, quote
            if clean == routes[$i].path
                if method === $(QuoteNode(M))
                    return (k(routes[$i], ()), true, mask)
                else
                    mask |= $(UInt8(_method_bit(M)))
                end
            end
        end)
    end
    push!(exprs, :(return (nothing, false, mask)))
    return Expr(:block, exprs...)
end

# First pattern that matches and serves the method wins; parse failure flags 400.
@generated function _scan_pattern(routes::Routes, method::Symbol, parts,
                                  mask::UInt8, k) where {Routes<:Tuple}
    exprs = Any[]
    for i in 1:length(Routes.parameters)
        RT = Routes.parameters[i]
        PT = RT.parameters[2]
        (_is_fixed(PT) || _is_catchall(PT)) && continue
        M = RT.parameters[1]
        push!(exprs, quote
            let params = _match_path($PT, parts, 1)
                if params isa ParamParseFail
                    parse_failed = true
                elseif params !== nothing
                    if method === $(QuoteNode(M))
                        return (k(routes[$i], params), mask, parse_failed)
                    else
                        mask |= $(UInt8(_method_bit(M)))
                    end
                end
            end
        end)
    end
    push!(exprs, :(return (nothing, mask, parse_failed)))
    return Expr(:block, :(parse_failed = false), exprs...)
end

# Catch-all pass: bare `"*"` routes, declaration order.
@generated function _scan_catchall(routes::Routes, method::Symbol, parts,
                                   mask::UInt8, k) where {Routes<:Tuple}
    exprs = Any[]
    for i in 1:length(Routes.parameters)
        RT = Routes.parameters[i]
        _is_catchall(RT.parameters[2]) || continue
        M = RT.parameters[1]
        push!(exprs, quote
            if method === $(QuoteNode(M))
                return (k(routes[$i], ()), mask)
            else
                mask |= $(UInt8(_method_bit(M)))
            end
        end)
    end
    push!(exprs, :(return (nothing, mask)))
    return Expr(:block, exprs...)
end

# --- Handler invocation (typed params, no erased callable) ---

@inline _handler_terminal(f::F, ::Tuple{}) where {F} = req -> f(req)
@inline _handler_terminal(f::F, params::Tuple) where {F} = req -> f(req, params...)

# @noinline is load-bearing: inlining the pipeline per route explodes compile memory.
Base.@noinline function _invoke_static(route::StaticRoute, ctx::RequestContext, req::Request, params)
    terminal = _handler_terminal(route.handler, params)
    return format_response(runpipeline(ctx.middlewares, route.middleware, req, terminal))
end

struct NotFoundTerminal end
(t::NotFoundTerminal)(r::Request) = Response(Plain, "404 Not Found"; status=404)

struct MethodNotAllowedTerminal
    mask::UInt8
end
(t::MethodNotAllowedTerminal)(r::Request) = _method_not_allowed(t.mask)

struct BadParamsTerminal end
(t::BadParamsTerminal)(r::Request) = Response(Plain, "400 Bad Request"; status=400)

@inline function _fallback_static(ctx::RequestContext, req::Request, mask::UInt8)
    terminal = mask == 0x00 ? NotFoundTerminal() : MethodNotAllowedTerminal(mask)
    return format_response(runpipeline(ctx.middlewares, (), req, terminal))
end

@inline function _bad_params_static(ctx::RequestContext, req::Request)
    return format_response(runpipeline(ctx.middlewares, (), req, BadParamsTerminal()))
end

function _dispatch_static(router::StaticRouter, ctx::RequestContext, req::Request)
    method = _normalize_method(req.method)
    clean = stripquery(req.uri)
    parts = _parts_for(Val(_has_patterns(router.routes)), clean)
    k = (route, params) -> _invoke_static(route, ctx, req, params)

    res, fixed_hit, mask = _scan_fixed(router.routes, method, clean, parts, UInt8(0), k)
    res === nothing || return res
    fixed_hit && return _fallback_static(ctx, req, mask)

    res, mask, parse_failed = _scan_pattern(router.routes, method, parts, mask, k)
    res === nothing || return res
    mask != 0x00 && return _fallback_static(ctx, req, mask)

    res, mask = _scan_catchall(router.routes, method, parts, UInt8(0), k)
    res === nothing || return res
    # A catch-all owns every path: a method mismatch there is a 405, and it
    # wins over another route's unparseable typed capture (matches `Router`).
    mask != 0x00 && return _fallback_static(ctx, req, mask)
    parse_failed && return _bad_params_static(ctx, req)
    return _fallback_static(ctx, req, mask)
end

# --- AbstractRouter protocol (for direct/plug-in use) ---

@inline function _matched_result(route::StaticRoute{M,PT,F,MW}, params) where {M,PT,F,MW}
    ep = Endpoint{F,MW,Nothing}(route.handler, route.middleware, nothing)
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

    res, mask, parse_failed = _scan_pattern(router.routes, m, parts, mask, k)
    res === nothing || return res
    mask != 0x00 && return MethodMismatch(mask)

    res, mask = _scan_catchall(router.routes, m, parts, UInt8(0), k)
    res === nothing || return res
    mask != 0x00 && return MethodMismatch(mask)
    parse_failed && return ParamMismatch()
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
    request = _attach_services(request, ctx.registries.services)
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
                T = _param_type(tname)
            end
            isempty(name) && error("@routes: parameter name is empty in '$path'")
            expr = :(PathCons{Cap{$(QuoteNode(Symbol(name))),$T},$expr})
        else
            expr = :(PathCons{Lit{$(QuoteNode(Symbol(part)))},$expr})
        end
    end
    return expr
end

# Join a group prefix with a route path at macro-expansion time.
function _path_join(prefix::AbstractString, path::AbstractString)::String
    p = rstrip(prefix, '/')
    isempty(p) && return String(path)
    path == "/" && return p
    return p * (startswith(path, '/') ? path : "/" * path)
end

function _route_expr(ex::Expr, prefix::AbstractString="", mws::Vector{Any}=Any[])
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
    full_path = _path_join(prefix, path)
    pathtype = _path_type_expr(full_path)
    # Middleware tuple: group middleware (outer → inner), then the route's own.
    # Each source may be a single middleware or a tuple; flatten both.
    sources = Any[mws...; mw_expr]
    flat = [:(asmiddlewaretuple($(esc(m)))...) for m in sources]
    return quote
        let h = $(esc(handler)), mw = ($(flat...),)
            StaticRoute{$(QuoteNode(fname)),$pathtype,typeof(h),typeof(mw)}($full_path, h, mw)
        end
    end
end

# Parse `group("prefix"; middleware=…) do g … end` into (prefix, mw, body).
function _group_parts(ex::Expr)
    ex.head === :do || error("@routes: expected a `group(…) do … end` block")
    call = ex.args[1]
    (call isa Expr && call.head === :call && call.args[1] === :group) ||
        error("@routes: expected `group(\"prefix\"; middleware=…)`")
    args = call.args[2:end]
    mw = nothing
    if !isempty(args) && args[1] isa Expr && args[1].head === :parameters
        for kw in args[1].args
            (kw isa Expr && kw.head === :kw && kw.args[1] === :middleware) ||
                error("@routes: only the `middleware` keyword is supported on group")
            mw = kw.args[2]
        end
        args = args[2:end]
    end
    (length(args) == 1 && args[1] isa String) ||
        error("@routes: expected `group(\"prefix\") do … end`")
    closure = ex.args[2]
    closure isa Expr && closure.head === :-> ||
        error("@routes: malformed group block")
    return args[1], mw, closure.args[2]
end

function _ws_expr(ex::Expr, prefix::AbstractString)
    (ex.head === :call && ex.args[1] === :ws) ||
        error("@routes: expected `ws(\"path\", handler; …)`")
    args = ex.args[2:end]
    on_open = nothing
    on_close = nothing
    allowed = nothing
    if !isempty(args) && args[1] isa Expr && args[1].head === :parameters
        for kw in args[1].args
            (kw isa Expr && kw.head === :kw) ||
                error("@routes: malformed ws keyword")
            key = kw.args[1]
            key === :on_open && (on_open = kw.args[2])
            key === :on_close && (on_close = kw.args[2])
            key === :allowed_origins && (allowed = kw.args[2])
            (key in (:on_open, :on_close, :allowed_origins)) ||
                error("@routes: unknown ws keyword `$key`")
        end
        args = args[2:end]
    end
    length(args) == 2 || error("@routes: expected `ws(\"path\", handler; …)`")
    path, handler = args
    path isa String || error("@routes: ws path must be a string literal")
    full = _path_join(prefix, path)
    return quote
        StaticWSRoute($full; on_message = $(esc(handler)),
                      on_open = $(esc(on_open)),
                      on_close = $(esc(on_close)),
                      allowed_origins = $(esc(allowed)))
    end
end

function _routes_from!(http::Vector{Any}, ws::Vector{Any}, block::Expr,
                       prefix::String, mws::Vector{Any})
    block.head === :block || (block = Expr(:block, block))
    for ex in block.args
        ex isa LineNumberNode && continue
        if ex isa Expr && ex.head === :do
            gprefix, gmw, body = _group_parts(ex)
            inner = gmw === nothing ? mws : [mws; gmw]
            _routes_from!(http, ws, body, _path_join(prefix, gprefix), inner)
        elseif ex isa Expr && ex.head === :call && ex.args[1] === :ws
            push!(ws, _ws_expr(ex, prefix))
        else
            push!(http, _route_expr(ex, prefix, mws))
        end
    end
    return http, ws
end

"""
    @routes begin
        get("/hello", req -> text("hi"))
        get("/users/:id::Int", (req, id) -> json((id = id,)))
        get("/files/*path", (req, path) -> text(path))
        post("/echo", req -> text(body(req)); middleware=(cors(),))
        ws("/chat", msg -> Message("Echo: \$(msg.data)"))

        group("/api"; middleware=(bearer(token),)) do api
            get("/items", list_items)
            group("/admin"; middleware=(require_admin,)) do admin
                delete("/items/:id::Int", delete_item)
            end
        end
    end

Build a [`StaticRouter`](@ref) from a block of route declarations. Paths are
parsed at macro-expansion time: `:name` captures a decoded `String`,
`:name::T` captures a parsed `T` (Int, Float64, Bool, …), `*name` captures the
rest of the path, and a bare `"*"` is the final fallback.

`group("prefix"; middleware=…) do … end` blocks are expanded at compile time:
paths are prefixed and middleware tuples concatenated (outer → inner → route),
so groups add no runtime structure. `ws("path", handler; on_open=, on_close=,
allowed_origins=)` declares a typed WebSocket endpoint. All three forms are
fully static.
"""
macro routes(block)
    block isa Expr && block.head === :block ||
        error("@routes expects a `begin ... end` block of route declarations")
    http = Any[]
    ws = Any[]
    _routes_from!(http, ws, block, "", Any[])
    return :(StaticRouter(($(http...),), ($(ws...),)))
end
