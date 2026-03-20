"""
    HTTP request handler — route matching, middleware execution, and response generation.
    Supports both dynamic routing (route!) and static dispatch (@router).
"""

"""
    execute_http_handler(server, request) → IdResponse

Dispatch to either static_dispatch (when @routes app is present) or
dynamic router (when using route! API).
"""
function execute_http_handler(server::AbstractServer, request::IdRequest)
    static = server.core.static

    # Static dispatch path — @router macro generated, fully trim-safe
    if !(static isa NoStaticRouter)
        return _static_http_handler(server, static, request)
    end

    # Dynamic dispatch path — route! API with Dict-based router
    return _dynamic_http_handler(server, request)
end

"""Static dispatch handler — calls the @router-generated dispatch function."""
function _static_http_handler(server::AbstractServer, static, request::IdRequest)
    # Body size check
    req_body = _get_body(request.payload)
    if sizeof(req_body) > server.core.max_body_size
        return IdResponse(request.id, Response(413, "Content-Type: text/plain\r\n", "413 Payload Too Large"))
    end

    try
        res = static_dispatch(static, request.payload)
        return IdResponse(request.id, res)
    catch e
        @error "Route handler error" exception=(e, catch_backtrace())
        return IdResponse(request.id, Response(500, "Content-Type: text/plain\r\n", "500 Internal Server Error"))
    end
end

"""Dynamic dispatch handler — uses Dict-based router and middleware pipeline."""
function _dynamic_http_handler(server::AbstractServer, request::IdRequest)
    router_obj = server.core.router

    req_body = _get_body(request.payload)
    if sizeof(req_body) > server.core.max_body_size
        return IdResponse(request.id, Response(413, "Content-Type: text/plain\r\n", "413 Payload Too Large"))
    end

    matched = match_route(router_obj, request.payload.method, request.payload.uri)

    if matched === nothing
        final_handler = (req, args...) -> Response(404, "Content-Type: text/plain\r\n", "404 Not Found")
        matched_params = EMPTY_PARAMS
    else
        handler = get(matched.handlers, request.payload.method, nothing)
        if handler === nothing
            final_handler = (req, args...) -> Response(405, "Content-Type: text/plain\r\n", "405 Method Not Allowed")
        else
            final_handler = handler
        end
        matched_params = matched.params
    end

    try
        res = execute_middleware(server.core.middlewares, request.payload, matched_params, final_handler)
        return IdResponse(request.id, res)
    catch e
        @error "Route handler failed to execute" exception=(e, catch_backtrace())
        return IdResponse(request.id, Response(500, "Content-Type: text/plain\r\n", "500 Internal Server Error"))
    end
end

"""Get body string from any request type."""
@inline function _get_body(req::Request)
    return req.body
end

@inline function _get_body(req::ViewRequest)
    return body(req)
end

@inline function _get_body(req::AbstractRequest)
    return ""
end
