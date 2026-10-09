"""
    Request processing pipeline — the transport-agnostic request seam.

    `process(ctx::RequestContext, req)` turns a `Kernel.Request`
    into a `Response`. It has no dependency on a server or on FFI types, so it
    can be exercised standalone (and by `FakeTransport`), and any transport (the C
    Mongoose adapter today, or a future pure-Julia one) can simply call it from
    its event loop.
"""

# --- Default error responses (module-level singletons) ---

const DEFAULT_500 = Response(Plain, "500 Internal Server Error"; status=500)
const DEFAULT_413 = Response(Plain, "413 Payload Too Large"; status=413)
const DEFAULT_503 = Response(Plain, "503 Service Unavailable"; status=503)
const DEFAULT_504 = Response(Plain, "504 Gateway Timeout"; status=504)

"""
    RequestContext{R,M,G} — the app-level typed registry bundle.

    Collapses the config that `process` needs into one object so the
    pipeline seam has a single argument: the router, the app-global middleware
    stack, and a `registries` NamedTuple holding the static error pages, the DI
    services, the typed dynamic error and exception handlers, and the lifecycle
    hooks (all concrete, so every call site is statically typed).

    The global middleware stack is stored as a **baked tuple snapshot** (built
    once by `App`/`use` and immutable afterward), so the per-request pipeline
    never re-grows or re-walks a mutable vector and needs no
    `[global; scoped]` concatenation.

    Standalone use (no server):
    ```julia
    ctx = RequestContext(router; errors=errs, services=(db=pool,))
    resp = process(ctx, Request(:get, "/", Dict{String,String}(), Pair{String,String}[], ""))
    ```
"""
struct RequestContext{R<:AbstractRouter, M<:Tuple, G<:NamedTuple}
    router::R
    middlewares::M
    registries::G
end

Base.show(io::IO, ctx::RequestContext) =
    print(io, "RequestContext(", length(ctx.middlewares), " middleware, ",
          length(ctx.registries.services), " services)")

# Untyped kwargs: annotations here would widen inference of the rebuilt context.
function RequestContext(router::AbstractRouter;
                        middlewares=(),
                        errors=Dict{Int,Response}(),
                        services=NamedTuple(),
                        error_handlers=(),
                        exception_handlers=(),
                        hooks_start=(),
                        hooks_stop=())
    errs = Dict{Int,Response}(k => v for (k, v) in errors)
    registries = (; errors=errs, services, error_handlers, exception_handlers,
                  hooks_start, hooks_stop)
    return RequestContext(router, Tuple(middlewares), registries)
end

# Rebuild a context with a new registries bundle while keeping router/middleware.
@inline function _rebuild_context(ctx::RequestContext{R,M}, registries::G2) where {R,M,G2<:NamedTuple}
    return RequestContext{R,M,G2}(ctx.router, ctx.middlewares, registries)
end

"""
    ErrorPage{F} — dynamic per-status error handler (`trap(app, status, f)`).

    The handler type is a type parameter, so resolving a page is a typed call
    (no abstract `Function` slot, trim-safe).
"""
struct ErrorPage{F}
    status::Int
    f::F
end

"""
    ExceptionHandler{E,F} — typed exception handler (`trap(app, E, f)`).
"""
struct ExceptionHandler{E<:Exception,F}
    f::F
end

@inline function _default_error(status::Int)::Response
    status == 500 && return DEFAULT_500
    status == 413 && return DEFAULT_413
    status == 503 && return DEFAULT_503
    status == 504 && return DEFAULT_504
    return Response(Plain, "$status $(statusreason(status))"; status=status)
end

@inline _scan_error_handlers(::Tuple{}, req::Union{Request,Nothing}, status::Int) = nothing

@inline function _scan_error_handlers(handlers::Tuple, req::Union{Request,Nothing}, status::Int)
    h = handlers[1]
    if h.status == status && req !== nothing
        return _try_error_page(h, req)
    end
    return _scan_error_handlers(Base.tail(handlers), req, status)
end

@inline function _try_error_page(h::ErrorPage, req::Request)::Response
    return try
        result = h.f(req)
        result isa Response ? result : _default_error(h.status)
    catch
        _default_error(h.status)
    end
end

@inline _has_error_handler(::Tuple{}, status::Int) = false
@inline function _has_error_handler(handlers::Tuple, status::Int)
    handlers[1].status == status && return true
    return _has_error_handler(Base.tail(handlers), status)
end

@inline _scan_exceptions(::Tuple{}, e, req) = (false, nothing)
@inline function _scan_exceptions(handlers::Tuple, e, req)
    found, res = _try_exception(handlers[1], e, req)
    found && return (true, res)
    return _scan_exceptions(Base.tail(handlers), e, req)
end

@inline _try_exception(h::ExceptionHandler{E,F}, e, req) where {E,F} =
    e isa E ? (true, h.f(req, e)) : (false, nothing)

"""
    errorresponse(ctx, req, status) → Response

Resolve the response for `status`: a static page first, then a dynamic handler
(in registration order), then the built-in default.
"""
@inline function errorresponse(ctx::RequestContext, req::Union{Request,Nothing},
                               status::Int)::Response
    page = get(ctx.registries.errors, status, nothing)
    page !== nothing && return page
    dynamic = _scan_error_handlers(ctx.registries.error_handlers, req, status)
    return dynamic === nothing ? _default_error(status) : dynamic
end

@inline errorresponse(ctx::RequestContext, status::Int) = errorresponse(ctx, nothing, status)

# --- Auto-serialization of non-Response handler returns ---

# Turn common handler returns into a Response (only the default fallback allocates).
@inline format_response(r::Response) = r
@inline format_response(s::StreamResponse{P}) where {P} = s
@inline format_response(x::AbstractString) = Response(Plain, String(x))
@inline format_response(x::Vector{UInt8}) =
    Response(200, ["Content-Type" => "application/octet-stream"], x)
@inline format_response(x::AbstractDict) = Response(Json, x)
@inline format_response(x::NamedTuple) = Response(Json, x)
@inline format_response(::Nothing) = Response(204, Pair{String,String}[], "")
@inline format_response(x) = Response(Plain, string(x))

# --- Allow header for 405 (RFC 9110 §15.5.6) — single source: the bitmask ---

# Built-in endpoint methods for the invocation protocol (defined here because
# `Endpoint` lives in router.jl, included after interface.jl).
@inline invokeendpoint(ep::Endpoint, request::Request, params) =
    isempty(params) ? ep.handler(request) : ep.handler(request, params...)
@inline scopedmiddleware(ep::Endpoint) = ep.middleware

@inline function _method_not_allowed(mask::UInt8)
    return Response(Plain, "405 Method Not Allowed"; status=405,
        headers=["Allow" => allow_from_bitmask(mask)])
end

"""
    _resolve_terminal(router, request) → (terminal, scoped_middleware)

Resolve a request into a `terminal` callable `(Request) → Response` and the
route's scoped middleware. The terminal is always a short-circuiting
404/405 producer when no handler matches, so middleware sees every request
exactly like the handler path.
"""
function _resolve_terminal(router::AbstractRouter, request::Request)
    compiled = getterminal(router, request)
    if compiled !== nothing
        # Frozen/compiled router: the terminal already fuses scoped middleware;
        # `nothing` marks scoped as baked-in.
        return compiled, nothing
    end

    result = matchroute(router, request.method, request.uri)
    if result isa NoMatch
        return ((r) -> Response(Plain, "404 Not Found"; status=404)), ()
    elseif result isa MethodMismatch
        return ((r) -> _method_not_allowed(result.allowed)), ()
    elseif result isa ParamMismatch
        return ((r) -> Response(Plain, "400 Bad Request"; status=400)), ()
    end

    ep = result.endpoint
    params = result.params
    return ((r) -> invokeendpoint(ep, r, params)), scopedmiddleware(ep)
end

# Built-in mapping for status-carrying exceptions: a custom error page for that
# status (trap(app, status, …)) wins; otherwise reply with the message.
@inline function _http_error_response(ctx::RequestContext, req::Request,
                                      status::Int, message::String,
                                      headers::Headers=Headers())::Response
    (haskey(ctx.registries.errors, status) || _has_error_handler(ctx.registries.error_handlers, status)) &&
        return errorresponse(ctx, req, status)
    isempty(headers) && push!(headers, "Content-Type" => "text/plain")
    return Response(status, headers, message)
end

# A caught `HTTPError` is the abstract UnionAll: dispatch on the `status` type
# parameter cannot be resolved by the trim verifier, so the mirrored field and
# `@nospecialize` keep the call resolvable.
@inline _http_error_response(ctx::RequestContext, req::Request, @nospecialize(e::HTTPError)) =
    _http_error_response(ctx, req, e.status, e.message, e.headers)

# --- HEAD body semantics (RFC 9110 §3.1) ---

"""
    _apply_head_semantics(result)

A `HEAD` response carries no body. If an explicit `HEAD` endpoint returns a
body from its handler, the transport drops it here before the response reaches
the wire; the (empty) response is then framed by mongoose's native machinery,
so no `Content-Length` header is set by this function (hand-writing it would
duplicate mongoose's own and force a non-native frame). Non-`Response`
(streaming) results and already bodyless responses pass through unchanged.
"""
function _apply_head_semantics(result)
    result isa Response || return result
    isempty(result.body) && return result
    return Response(result.status, result.headers, "")
end

"""
    process(ctx::RequestContext, request) → Response

Run the full pipeline: attach services to the request context, dispatch the
request through any middleware then the router, apply custom error responses
for 4xx/5xx results, and map thrown exceptions (typed `trap` handlers
first, then the built-in `HTTPError`/`ValidationError` mapping).

# Arguments
- `ctx::RequestContext` — router, middleware stack, error pages, DI services,
  and typed exception handlers (see `RequestContext`).
- `request::Request` — the transport-agnostic request.

Middleware is composed with the matched route's scoped `Endpoint` middleware
(`global → group/route → handler`), and it wraps *every* terminal — including
the 404/405 producers — so interception middleware (CORS, health,
metrics) observes all requests.
"""
function process(ctx::RequestContext, request::Request)::Union{Response,StreamResponse}
    request = _attach_services(request, ctx.registries.services)
    return _guarded_process(ctx, request) do
        _process_pipeline(ctx, request)
    end
end

@inline function _process_pipeline(ctx::RequestContext, request::Request)
    terminal, scoped = _resolve_terminal(ctx.router, request)
    result = if scoped === nothing
        # Compiled path: scoped middleware is already fused into the terminal,
        # so the baked global stack wraps it directly.
        isempty(ctx.middlewares) ? terminal(request) :
            runpipeline(ctx.middlewares, request, terminal)
    else
        # Generic path: global stack + route-scoped stack, walked with a
        # single cursor (no per-request [global; scoped] concatenation).
        runpipeline(ctx.middlewares, scoped, request, terminal)
    end
    # Auto-serialize non-Response returns (String/Dict/bytes/nothing/…).
    return format_response(result)
end

# Shared exception/error-page guard for every dispatch strategy.
@inline function _guarded_process(dispatch::F, ctx::RequestContext, request::Request) where {F}
    try
        result = dispatch()
        if result isa Response &&
           (haskey(ctx.registries.errors, result.status) || _has_error_handler(ctx.registries.error_handlers, result.status))
            return errorresponse(ctx, request, result.status)
        end
        return result
    catch e
        found, res = _scan_exceptions(ctx.registries.exception_handlers, e, request)
        found && return res
        e isa HTTPError     && return _http_error_response(ctx, request, e)
        e isa ValidationError && return _http_error_response(ctx, request, 422, e.message)
        rethrow(e)
    end
end
