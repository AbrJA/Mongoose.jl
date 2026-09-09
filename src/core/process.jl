"""
    Request processing pipeline — the transport-agnostic request seam.

    `invoke_request(ctx::RequestContext, req)` turns a `MongooseCore.Request`
    into a `Response`. It has no dependency on a server or on FFI types, so it
    can be exercised standalone (and by `TestClient`), and any transport (the C
    Mongoose adapter today, or a future pure-Julia one) can simply call it from
    its event loop.
"""

# --- Default error responses (module-level singletons) ---

const DEFAULT_500 = Response(Plain, "500 Internal Server Error"; status=500)
const DEFAULT_413 = Response(Plain, "413 Payload Too Large"; status=413)
const DEFAULT_503 = Response(Plain, "503 Service Unavailable"; status=503)
const DEFAULT_504 = Response(Plain, "504 Gateway Timeout"; status=504)

"""
    error_response(errors, status) → Response

Look up a custom error response, falling back to module defaults.
`errors` maps HTTP status codes to a static `Response` or `Function(req)`.
"""
@inline function error_response(errors::Dict{Int,Union{Response,Function}},
                                req::Union{Request,Nothing}, status::Int)::Response
    custom = get(errors, status, nothing)
    if custom !== nothing
        custom isa Response && return custom
        custom isa Function && req !== nothing && return try
            result = custom(req)
            result isa Response ? result : Response(Plain, "$status $(status_reason(status))"; status=status)
        catch
            Response(Plain, "$status $(status_reason(status))"; status=status)
        end
    end
    status == 500 && return DEFAULT_500
    status == 413 && return DEFAULT_413
    status == 503 && return DEFAULT_503
    status == 504 && return DEFAULT_504
    return Response(Plain, "$status $(status_reason(status))"; status=status)
end

@inline error_response(errors::Dict{Int,Union{Response,Function}}, status::Int) =
    error_response(errors, nothing, status)

"""
    RequestContext{R,M,E,S,H} — the app-level request-processing bundle.

    Collapses the config that `invoke_request` needs into one object so the
    pipeline seam has a single argument: the router, the global middleware
    stack, the status→error-page map, the DI services, and the typed exception
    handlers.

    Fields are plain references to the contributor's own containers (a `Router`,
    the app's middleware `Vector`, its `errors`/`exception_handlers` `Dict`s),
    so mutations made during the build phase (before `start!`) are visible to
    the seam without rebuilding.

    Standalone use (no server):
    ```julia
    ctx = RequestContext(router; errors=errs, services=(db=pool,))
    resp = invoke_request(ctx, Request(:get, "/", Dict{String,String}(), Pair{String,String}[], ""))
    ```
"""
struct RequestContext{R<:AbstractRouter,
                      M<:AbstractVector{<:AbstractMiddleware},
                      E,
                      S<:NamedTuple,
                      H<:AbstractDict{DataType,Function}}
    router::R
    middlewares::M
    errors::E
    services::S
    exception_handlers::H
end

function RequestContext(router::AbstractRouter;
                        middlewares::AbstractVector{<:AbstractMiddleware}=AbstractMiddleware[],
                        errors::AbstractDict{Int}=Dict{Int,Union{Response,Function}}(),
                        services::NamedTuple=NamedTuple(),
                        exception_handlers::AbstractDict{DataType,Function}=Dict{DataType,Function}())
    return RequestContext(router, middlewares, errors, services, exception_handlers)
end

# --- Auto-serialization of non-Response handler returns ---

# A handler may return anything; these methods turn the common shapes into a
# Response so `return Dict(...)`/`return "text"` just work (only the default
# fallback allocates) and raw returns can never silently 500.
@inline format_response(r::Response) = r
@inline format_response(s::StreamResponse) = s
@inline format_response(x::AbstractString) = Response(Plain, String(x))
@inline format_response(x::Vector{UInt8}) =
    Response(200, ["Content-Type" => "application/octet-stream"], x)
@inline format_response(x::AbstractDict) = Response(Json, x)
@inline format_response(x::NamedTuple) = Response(Json, x)
@inline format_response(::Nothing) = Response(204, Pair{String,String}[], "")
@inline format_response(x) = Response(Plain, string(x))

# --- Allow header for 405 (RFC 9110 §15.5.6) — single source: the bitmask ---

@inline _allow_header(mm::MethodMap) = allow_from_bitmask(method_bitmask(mm))

@inline function _method_not_allowed(mask::UInt8)
    return Response(Plain, "405 Method Not Allowed"; status=405,
        headers=["Allow" => allow_from_bitmask(mask)])
end

@inline _call_endpoint(ep::Endpoint, params, req::Request) =
    isempty(params) ? ep.handler(req) : ep.handler(req, params...)

"""
    _resolve_terminal(router, request) → (terminal, scoped_middleware)

Resolve a request into a `terminal` callable `(Request) → Response` and the
route's scoped middleware. The terminal is always a short-circuiting
404/405 (or auto-HEAD) producer when no handler matches, so middleware sees
every request exactly like the handler path.
"""
function _resolve_terminal(router::AbstractRouter, request::Request)
    compiled = terminal_for(router, request)
    if compiled !== nothing
        # Frozen/compiled router: the terminal already fuses scoped middleware
        # (and any auto-HEAD stripping); `nothing` marks scoped as baked-in.
        return compiled, nothing
    end

    result = match_route(router, request.method, request.uri)
    if result isa NotFound
        return ((r) -> Response(Plain, "404 Not Found"; status=404)), AbstractMiddleware[]
    elseif result isa MethodNotAllowed
        return ((r) -> _method_not_allowed(result.allowed)), AbstractMiddleware[]
    end

    ep = result.endpoint::Endpoint
    params = result.params
    if request.method === :head && get_endpoint(result.handlers, :head) === nothing
        # Auto-HEAD: the router resolved the GET endpoint; run it and strip.
        strip = (r) -> begin
            resp = format_response(_call_endpoint(ep, params, r))
            resp isa Response ? Response(resp.status, resp.headers, "") : resp
        end
        return strip, ep.middleware
    end
    return ((r) -> _call_endpoint(ep, params, r)), ep.middleware
end

# Built-in mapping for status-carrying exceptions: a custom error page for that
# status (onerror!(app, status, …)) wins; otherwise reply with the message.
@inline function _http_error_response(ctx::RequestContext, req::Request,
                                      status::Int, message::String,
                                      headers::Headers=Headers())::Response
    haskey(ctx.errors, status) && return error_response(ctx.errors, req, status)
    isempty(headers) && push!(headers, "content-type" => "text/plain")
    return Response(status, headers, message)
end

@inline _http_error_response(ctx::RequestContext, req::Request, e::HTTPError{status}) where {status} =
    _http_error_response(ctx, req, status, e.message, e.headers)

"""
    invoke_request(ctx::RequestContext, request) → Response

Run the full pipeline: attach services to the request context, dispatch the
request through any middleware then the router, apply custom error responses
for 4xx/5xx results, and map thrown exceptions (typed `onerror!` handlers
first, then the built-in `HTTPError`/`ValidationError` mapping).

# Arguments
- `ctx::RequestContext` — router, middleware stack, error pages, DI services,
  and typed exception handlers (see `RequestContext`).
- `request::Request` — the transport-agnostic request.

Middleware is composed with the matched route's scoped `Endpoint` middleware
(`global → group/route → handler`), and it wraps *every* terminal — including
the 404/405/auto-HEAD producers — so interception middleware (CORS, health,
metrics) observes all requests.
"""
function invoke_request(ctx::RequestContext, request::Request)::Union{Response,StreamResponse}
    if !isempty(ctx.services)
        c = context(request)
        c[:_services] = ctx.services
    end
    try
        terminal, scoped = _resolve_terminal(ctx.router, request)
        result = if isempty(ctx.middlewares) && (scoped === nothing || isempty(scoped))
            terminal(request)
        elseif scoped === nothing
            # Compiled path: scoped middleware is already fused into the terminal,
            # so global middleware wraps it directly (no per-request concat).
            execute_pipeline(ctx.middlewares, request, terminal)
        else
            execute_pipeline([ctx.middlewares; scoped], request, terminal)
        end

        # Auto-serialize non-Response returns (String/Dict/bytes/nothing/…).
        result = format_response(result)

        if result isa Response && haskey(ctx.errors, result.status)
            return error_response(ctx.errors, request, result.status)
        end
        return result
    catch e
        for (T, handler) in ctx.exception_handlers
            e isa T && return handler(request, e)
        end
        e isa HTTPError     && return _http_error_response(ctx, request, e)
        e isa ValidationError && return _http_error_response(ctx, request, 422, e.message)
        rethrow(e)
    end
end
