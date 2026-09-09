"""
    Compiled frozen-route dispatch.

    `freeze!(router)` compiles the closed route table into a
    `CompiledDispatch`. The pipeline then resolves a request through
    `terminal_for` (see `interface.jl`) instead of the generic
    `dispatch_route` path, so the hot path:

    - never allocates a per-request closure or `[global; scoped]` concat,
    - never splits the path into a `Vector{String}` (parametric matching walks
      the raw path with byte indices),
    - pre-bakes each route's terminal at freeze time, capturing the handler's
      concrete type so the handler call is statically resolvable,
    - runs parametric matching through a **heterogeneous tuple chain** built by
      folding at freeze time — each route node is a statically-known type, so
      each match/parse step is specialized (bounded-union results, no boxing).

    Semantics are identical to the generic path: exact (fixed) matches win,
    parametric routes resolve in registration order, the `"*"` catch-all is
    the final fallback, missing methods produce 405, and HEAD falls back to the
    GET endpoint with the body stripped.
"""

# --- Prebuilt 0-arity terminal: calls a handler with a baked concrete type ---

# Pre-built short-circuit terminals (immutable singletons; mirror the generic
# path's inline 404/405 producers).
const TERM_404 = (req) -> Response(Plain, "404 Not Found"; status=404)

"""
    Terminal{H} — pre-built terminal for a fixed route / catch-all.

    Captures `handler::H` (the concrete type at freeze time) so
    `t(req)` is a statically-resolvable `handler(req)` call.
"""
struct Terminal{H}
    handler::H
end
(t::Terminal)(req::Request) = t.handler(req)

"""
    ParamCall{H,P} — pre-built parametric handler call.

    `(c)(req, p::P)` splats the statically-typed param tuple, so the handler
    call is statically-resolvable for the route's param signature.
"""
struct ParamCall{H,P}
    handler::H
end
(c::ParamCall{H,P})(req::Request, p::P) where {H,P} = c.handler(req, p...)

"""
    BoundParams{F,P} — request-time binding of params to a baked thunk.

    The parametric action slot holds a `(req, p::P) → Response` thunk (its
    body is static); `BoundParams` binds the concrete match tuple `p` so the
    pipeline can call it as a 0-arity terminal. One small block per request —
    the only per-request allocation on the compiled parametric path.
"""
struct BoundParams{F,P}
    thunk::F
    p::P
end
(b::BoundParams)(req::Request) = b.thunk(req, b.p)

# --- Compile-time action baking ---

# Wrap a 0-arity terminal in its route-scoped middleware (once, at freeze).
@inline function _wrap_scoped(inner::Function, mws::Vector{AbstractMiddleware})::Function
    isempty(mws) && return inner
    return (req) -> execute_pipeline(mws, req, inner)
end

# Bake a fixed-route action: concrete handler type captured in `Terminal`.
@inline function _bake_action(ep::Endpoint)::Function
    inner = Terminal{typeof(ep.handler)}(ep.handler)
    return _wrap_scoped((req) -> inner(req), ep.middleware)
end

# Bake the auto-HEAD action: run the GET terminal, strip the body.
@inline function _bake_head_action(ep::Endpoint)::Function
    inner = Terminal{typeof(ep.handler)}(ep.handler)
    stripped = (req) -> begin
        resp = inner(req)
        resp isa Response ? Response(resp.status, resp.headers, "") : resp
    end
    return _wrap_scoped(stripped, ep.middleware)
end

@inline _bake_slot(::Nothing) = nothing
@inline _bake_slot(ep::Endpoint) = _bake_action(ep)

# HEAD slot: explicit HEAD endpoint wins; otherwise auto-strip the GET one.
@inline _bake_head_slot(ep::Endpoint, ::Any) = _bake_action(ep)
@inline _bake_head_slot(::Nothing, get_ep::Endpoint) = _bake_head_action(get_ep)
@inline _bake_head_slot(::Nothing, ::Nothing) = nothing

# Bake a parametric action slot. Runs once per route at freeze time: `PC` is
# the route's concrete call tuple type (dispatched dynamically, e.g.
# `Tuple{Int,String}`), and `typeof(ep.handler)` is folded into
# `ParamCall{...}` so the resulting `BoundParams` terminal is statically typed
# even though `Endpoint.handler` is stored as `Function`.
@inline function _bake_param_slot(ep::Endpoint, ::Type{P})::Function where {P}
    call = ParamCall{typeof(ep.handler), P}(ep.handler)
    plain = (req, p::P) -> call(req, p)
    mws = ep.middleware
    isempty(mws) && return (p::P) -> BoundParams{typeof(plain), P}(plain, p)
    return (p::P) -> BoundParams{ScopedParamCall{P,typeof(plain)}, P}(
        ScopedParamCall{P,typeof(plain)}(mws, plain), p)
end
@inline _bake_param_slot(::Nothing, ::Type) = nothing

# Auto-HEAD for parametric routes: strip the GET body after binding params.
@inline function _bake_param_head_slot(ep::Endpoint, ::Type{P})::Function where {P}
    call = ParamCall{typeof(ep.handler), P}(ep.handler)
    stripped = (req, p::P) -> begin
        resp = call(req, p)
        resp isa Response ? Response(resp.status, resp.headers, "") : resp
    end
    mws = ep.middleware
    isempty(mws) && return (p::P) -> BoundParams{typeof(stripped), P}(stripped, p)
    return (p::P) -> BoundParams{ScopedParamCall{P,typeof(stripped)}, P}(
        ScopedParamCall{P,typeof(stripped)}(mws, stripped), p)
end
@inline _bake_param_head_slot(::Nothing, get_ep::Endpoint, ::Type{P}) where {P} =
    _bake_param_head_slot(get_ep, P)
@inline _bake_param_head_slot(::Nothing, ::Nothing, ::Type) = nothing

# Scoped parametric thunk: runs the route-scoped middleware around the plain
# terminal at request time (middleware list is pre-built per route).
struct ScopedParamCall{P,F}
    mws::Vector{AbstractMiddleware}
    plain::F
end
(spc::ScopedParamCall{P,F})(req::Request, p::P) where {P,F} =
    execute_pipeline(spc.mws, req, BoundParams{typeof(spc.plain), P}(spc.plain, p))

# --- Compiled nodes ---

"""
    CompiledPath — one frozen fixed path: original MethodMap (for
    `dispatch_route` compatibility) plus 7 pre-baked 0-arity terminals.
"""
struct CompiledPath
    methods::MethodMap
    not_allowed::Function            # (req) -> 405 Response with Allow header
    get::Union{Nothing,Function}
    post::Union{Nothing,Function}
    put::Union{Nothing,Function}
    delete::Union{Nothing,Function}
    patch::Union{Nothing,Function}
    options::Union{Nothing,Function}
    head::Union{Nothing,Function}
end

@inline function _compile_path(fr::FixedRoute)
    mm = fr.handlers
    return CompiledPath(mm, (r) -> _method_not_allowed(mm),
        _bake_slot(mm.get), _bake_slot(mm.post), _bake_slot(mm.put),
        _bake_slot(mm.delete), _bake_slot(mm.patch), _bake_slot(mm.options),
        _bake_head_slot(mm.head, mm.get))
end

"""
    CompiledParam{P,N} — one frozen parametric route.

    `route::ParamRoute{P,N}` keeps the pattern + MethodMap (registration-order
    dispatch semantics and `dispatch_route` compatibility); `ops` is the
    heterogeneous tuple of compiled segment ops (`LitOp`/`CaptureOp`/`WildOp`)
    built at freeze time, making the matcher fully static per route. The 7
    slots hold `(req, p::P) → Response` thunks, bound to request params at
    dispatch time.
"""
struct CompiledParam{P,N}
    route::ParamRoute{P,N}
    ops::Tuple
    not_allowed::Function            # (req) -> 405 Response with Allow header
    get::Union{Nothing,Function}
    post::Union{Nothing,Function}
    put::Union{Nothing,Function}
    delete::Union{Nothing,Function}
    patch::Union{Nothing,Function}
    options::Union{Nothing,Function}
    head::Union{Nothing,Function}
end

# The concrete param tuple type produced at match time. `route.param_types`
# holds the *types as values* (e.g. `(Int, String)`), so the concrete call type
# is `Tuple{Int,String}`; wildcard captures collapse to `String`.
@inline _parse_result_type(::Type{String}) = String
@inline _parse_result_type(::Type{T}) where {T} = T
@inline _parse_result_type(::Type{WildcardParam}) = String

@inline function _call_param_type(route::ParamRoute)::Type
    return Tuple{_parse_result_type.(route.param_types)...}
end

@inline function _compile_param(route::ParamRoute{P,N}) where {P,N}
    mm = route.handlers
    PC = _call_param_type(route)
    return CompiledParam{P,N}(route, _build_ops(route.segments),
        (r) -> _method_not_allowed(mm),
        _bake_param_slot(mm.get, PC), _bake_param_slot(mm.post, PC),
        _bake_param_slot(mm.put, PC), _bake_param_slot(mm.delete, PC),
        _bake_param_slot(mm.patch, PC), _bake_param_slot(mm.options, PC),
        _bake_param_head_slot(mm.head, mm.get, PC))
end

# Build the heterogeneous route chain by folding (each element keeps its
# concrete type, so `_scan`'s recursion is unrolled and specialized per node).
function _build_chain(routes::Vector{ParamRoute})
    acc = ()
    for route in routes
        acc = (acc..., _compile_param(route))
    end
    return acc
end

"""
    CompiledDispatch <: AbstractCompiledDispatch — frozen route table.

    `fixed` keeps the O(1) exact-match dict (terminals pre-baked);
    `chain` is a statically-typed tuple of `CompiledParam` nodes scanned in
    registration order; `wildcard` is the `"*"` catch-all node.
"""
struct CompiledDispatch <: AbstractCompiledDispatch
    fixed::Dict{String,CompiledPath}
    chain::Tuple
    wildcard::Union{Nothing,CompiledPath}
end

function _compile!(r::Router)
    fixed = Dict{String,CompiledPath}()
    for (path, fr) in r.fixed
        path == "*" && continue
        fixed[path] = _compile_path(fr)
    end
    wild = get(r.fixed, "*", nothing)
    wildcard = wild === nothing ? nothing : _compile_path(wild)
    return CompiledDispatch(fixed, _build_chain(r.param_routes), wildcard)
end

# --- Index-walking path matcher (no Vector{String} split) ---

# Per-segment compiled ops (heterogeneous tuple per route). The parse closure
# of a `CaptureOp` is baked at freeze time with the segment's concrete param
# type, so the walk below is fully static per route (no runtime dispatch on
# `Type` values).
struct LitOp
    text::String
end
struct CaptureOp{F}
    parse::F
end
struct WildOp end

# Bake a parse closure specialized on the concrete param type `T`. The dynamic
# dispatch on the `::Type` value happens once per route at freeze time; the
# returned closure body is statically typed.
@inline function _make_parser(::Type{String})
    # `s` is an owned String and the span [j0, j1) is char-aligned, so the
    # zero-copy decode fast path applies when the segment is plain.
    return (s, j0, j1) -> decode_path_segment(s, j0, j1 - 1)
end
@inline function _make_parser(::Type{T}) where {T}
    return (s, j0, j1) -> tryparse(T, decode_path_segment(s, j0, j1 - 1))
end

@inline function _seg_op(seg::PatternSegment)
    if seg.T === WildcardParam
        return WildOp()
    elseif seg.is_param
        return CaptureOp(_make_parser(seg.T))
    else
        return LitOp(seg.text)
    end
end

function _build_ops(segs::Vector{PatternSegment})
    ops = ()
    for seg in segs
        ops = (ops..., _seg_op(seg))
    end
    return ops
end

# Locate the next non-empty segment of `s` starting at byte index `i`.
# Returns `(j0, j1, next_i)` where the segment spans `j0:j1-1` (j0 == 0 when
# exhausted). No SubString is created, so literal comparison and typed parsing
# work on byte spans of the original path (zero allocation).
@inline function _next_seg(s::AbstractString, i::Int)
    n = ncodeunits(s)
    while i <= n && codeunit(s, i) == UInt8('/')
        i += 1
    end
    i > n && return (0, 0, i)
    j = i
    while j <= n && codeunit(s, j) != UInt8('/')
        j += 1
    end
    return (i, j, j)
end

# Byte-span equality with a literal segment (zero allocation).
@inline function _bytes_eq(s::AbstractString, j0::Int, j1::Int, text::String)::Bool
    (j1 - j0) == ncodeunits(text) || return false
    k = 1
    while j0 < j1
        codeunit(s, j0) == codeunit(text, k) || return false
        j0 += 1
        k += 1
    end
    return true
end

@inline function _only_slashes(s::AbstractString, i::Int)::Bool
    n = ncodeunits(s)
    while i <= n
        codeunit(s, i) == UInt8('/') || return false
        i += 1
    end
    return true
end

# Join the remaining non-empty segments (collapse "//") — matches
# `join(split(..., keepempty=false), "/")` exactly.
@inline function _join_tail(s::AbstractString, i::Int)::String
    n = ncodeunits(s)
    while i <= n && codeunit(s, i) == UInt8('/')
        i += 1
    end
    i > n && return ""
    buf = UInt8[]
    first = true
    while i <= n
        j = i
        while j <= n && codeunit(s, j) != UInt8('/')
            j += 1
        end
        first || push!(buf, UInt8('/'))
        for k in i:(j - 1)
            push!(buf, codeunit(s, k))
        end
        first = false
        i = j
        while i <= n && codeunit(s, i) == UInt8('/')
            i += 1
        end
    end
    return String(buf)
end

# Walk the compiled ops against `s`, building the typed param tuple.
# Fully static per route: the ops tuple is heterogeneous, each op carries a
# baked (statically-typed) action, and the growing result tuple stays concrete.
# Returns `Union{Nothing, <:Tuple}`; `nothing` = no match.
@inline _walk_ops(::Tuple{}, s::AbstractString, i::Int, out) =
    _only_slashes(s, i) ? out : nothing
@inline function _walk_ops(ops::Tuple, s::AbstractString, i::Int, out)
    op = ops[1]
    rest = Base.tail(ops)
    if op isa LitOp
        j0, j1, ni = _next_seg(s, i)
        (j0 == 0 || _bytes_eq(s, j0, j1, op.text)) || return nothing
        return _walk_ops(rest, s, ni, out)
    elseif op isa CaptureOp
        j0, j1, ni = _next_seg(s, i)
        j0 == 0 && return nothing
        p = op.parse(s, j0, j1)
        p === nothing && return nothing
        return _walk_ops(rest, s, ni, (out..., p))
    else # WildOp — consumes every remaining segment, marks the path as walked.
        raw = _join_tail(s, i)
        v = decode_path_segment(raw)
        return _walk_ops(rest, s, ncodeunits(s) + 1, (out..., v))
    end
end

@inline function _walk_segs(node::CompiledParam, s::AbstractString)
    return _walk_ops(node.ops, s, 1, ())
end

# --- Dispatch through the compiled table ---

# Fixed/catch-all node: method → baked terminal, else 405.
@inline function _action(p::CompiledPath, method::Symbol)::Function
    method === :get     && (t = p.get;     t !== nothing && return t)
    method === :post    && (t = p.post;    t !== nothing && return t)
    method === :put     && (t = p.put;     t !== nothing && return t)
    method === :delete  && (t = p.delete;  t !== nothing && return t)
    method === :patch   && (t = p.patch;   t !== nothing && return t)
    method === :options && (t = p.options; t !== nothing && return t)
    method === :head    && (t = p.head;    t !== nothing && return t)
    return p.not_allowed
end

# Parametric node: bind the matched tuple through the baked terminal factory.
@inline function _param_action(node::CompiledParam, method::Symbol, p)
    method === :get     && (t = node.get;     t !== nothing && return t(p))
    method === :post    && (t = node.post;    t !== nothing && return t(p))
    method === :put     && (t = node.put;     t !== nothing && return t(p))
    method === :delete  && (t = node.delete;  t !== nothing && return t(p))
    method === :patch   && (t = node.patch;   t !== nothing && return t(p))
    method === :options && (t = node.options; t !== nothing && return t(p))
    method === :head    && (t = node.head;    t !== nothing && return t(p))
    return node.not_allowed
end

# Static recursion over the heterogeneous chain (unrolled per node).
@inline _scan(::Tuple{}, method::Symbol, clean::AbstractString) = nothing
@inline function _scan(chain::Tuple, method::Symbol, clean::AbstractString)
    node = chain[1]
    p = _walk_segs(node, clean)
    p === nothing && return _scan(Base.tail(chain), method, clean)
    return _param_action(node, method, p)
end

"""
    _compiled_terminal(d, method, clean) → callable

Resolve a frozen request into a pre-built terminal (a `Function` or a
`BoundParams` functor). Fixed paths first, then parametric routes in
registration order, then the `"*"` catch-all; no match yields the pre-built
404 terminal.
"""
@inline function _compiled_terminal(d::CompiledDispatch, method::Symbol,
                                    clean::AbstractString)
    p = get(d.fixed, clean, nothing)
    p !== nothing && return _action(p, method)
    t = _scan(d.chain, method, clean)
    t === nothing || return t
    w = d.wildcard
    w !== nothing && return _action(w, method)
    return TERM_404
end

# --- Pipeline entry point ---

function terminal_for(r::Router, req::Request)
    c = r.compiled
    c === nothing && return nothing
    return _compiled_terminal(c, req.method, strip_query(req.uri))
end
