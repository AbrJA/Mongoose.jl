"""
    Request processing pipeline — the transport-agnostic request seam.

    `invoke_request(router, middlewares, errors, services, req)` turns a
    `MongooseCore.Request` into a `Response`. It has no dependency on a server
    or on FFI types, so it can be exercised standalone (and by `TestClient`),
    and any transport (the C Mongoose adapter today, or a future pure-Julia
    one) can simply call it from its event loop.
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

# --- Handler invocation ---

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

"""
    invoke_request(router, middlewares, errors, services, request) → Response

Run the full pipeline: attach services to the request context, dispatch the
request through any middleware then the router, and apply custom error
responses for 4xx/5xx results.

# Arguments
- `router::AbstractRouter` — route table (see the router protocol).
- `middlewares::AbstractVector{<:AbstractMiddleware}` — app-global middleware stack.
- `errors` — `Dict{Int,Union{Response,Function}}` of custom error responses.
- `services::NamedTuple` — dependency-injection services (may be empty).
- `request::Request` — the transport-agnostic request.

Middleware is composed with the matched route's scoped `Endpoint` middleware
(`global → group/route → handler`), and it wraps *every* terminal — including
the 404/405/auto-HEAD producers — so interception middleware (CORS, health,
metrics) observes all requests.
"""
function invoke_request(router::AbstractRouter, middlewares::AbstractVector{<:AbstractMiddleware},
                        errors::Dict{Int,Union{Response,Function}},
                        services::NamedTuple, request::Request)::Union{Response,StreamResponse}
    if !isempty(services)
        ctx = context(request)
        ctx[:_services] = services
    end

    terminal, scoped = _resolve_terminal(router, request)
    result = if isempty(middlewares) && (scoped === nothing || isempty(scoped))
        terminal(request)
    elseif scoped === nothing
        # Compiled path: scoped middleware is already fused into the terminal,
        # so global middleware wraps it directly (no per-request concat).
        execute_pipeline(middlewares, request, terminal)
    else
        execute_pipeline([middlewares; scoped], request, terminal)
    end

    # Auto-serialize non-Response returns (String/Dict/bytes/nothing/…).
    result = format_response(result)

    if result isa Response && haskey(errors, result.status)
        return error_response(errors, request, result.status)
    end
    return result
end
