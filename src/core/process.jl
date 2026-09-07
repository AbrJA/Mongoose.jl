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

"""
    dispatch_to_handler(router, request) → Union{Response, StreamResponse}

Route a request to its handler. Handles 404, 405, and auto-HEAD.
"""
function dispatch_to_handler(router::AbstractRouter, req::Request)::Union{Response,StreamResponse}
    matched = dispatch_route(router, req.method, req.uri)
    if matched !== nothing
        handler = get_handler(matched, req.method)
        if handler !== nothing
            params = matched.params
            result = isempty(params) ? handler(req) : handler(req, params...)
            result isa Union{Response,StreamResponse} || throw(TypeError(:dispatch_to_handler, Union{Response,StreamResponse}, result))
            return result
        end
        # Auto-HEAD: try GET handler, strip body
        if req.method === :head
            get_h = get_handler(matched, :get)
            if get_h !== nothing
                params = matched.params
                resp = isempty(params) ? get_h(req) : get_h(req, params...)
                resp isa Response && return Response(resp.status, resp.headers, "")
                resp isa StreamResponse && return resp
            end
        end
        return Response(Plain, "405 Method Not Allowed"; status=405)
    end
    return Response(Plain, "404 Not Found"; status=404)
end

"""
    invoke_request(router, middlewares, errors, services, request) → Response

Run the full pipeline: attach services to the request context, dispatch the
request through any middleware then the router, and apply custom error
responses for 4xx/5xx results.

# Arguments
- `router::AbstractRouter` — route table (see the router protocol).
- `middlewares::Vector{AbstractMiddleware}` — app-level middleware stack.
- `errors` — `Dict{Int,Union{Response,Function}}` of custom error responses.
- `services` — `Dict{Symbol,Any}` of dependency-injection services (may be empty).
- `request::Request` — the transport-agnostic request.
"""
function invoke_request(router::AbstractRouter, middlewares::Vector{AbstractMiddleware},
                        errors::Dict{Int,Union{Response,Function}},
                        services::Dict{Symbol,Any}, request::Request)::Union{Response,StreamResponse}
    if !isempty(services)
        ctx = context(request)
        ctx[:_services] = services
    end

    result = if isempty(middlewares)
        dispatch_to_handler(router, request)
    else
        final = (r) -> dispatch_to_handler(router, r)
        execute_pipeline(middlewares, request, final)
    end

    if result isa Response && haskey(errors, result.status)
        return error_response(errors, request, result.status)
    end
    return result
end