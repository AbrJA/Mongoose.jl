"""
    HTTP request handler — route matching, middleware execution, and response generation.
"""

"""
    execute_http_handler(server, request) → IdResponse

Match the request against registered routes, execute the middleware pipeline
and handler, and return a tagged response. Returns 404, 405, 413, or 500
responses for unmatched routes, wrong methods, oversized bodies, and errors.

Middleware is always executed first — this allows middleware like CORS to
intercept OPTIONS preflight requests before route matching.
"""
function execute_http_handler(server::Server, request::IdRequest)
    router_obj = server.core.router

    # Check body size limit
    req_body = if request.payload isa HttpRequest
        request.payload.body
    elseif request.payload isa ViewRequest
        body(request.payload)
    else
        ""
    end
    
    if sizeof(req_body) > server.core.max_body_size
        res = HttpResponse(413, "Content-Type: text/plain\r\n", "413 Payload Too Large")
        return IdResponse(request.id, res)
    end
    
    # Route matching
    matched = match_route(router_obj, request.payload.method, request.payload.uri)
    
    # Determine the final handler (route handler or 404/405 fallback)
    if matched === nothing
        final_handler = Handler((req, params) -> HttpResponse(404, "Content-Type: text/plain\r\n", "404 Not Found"))
        matched_params = EMPTY_PARAMS
    else
        handler = get(matched.handlers, request.payload.method, nothing)
        if handler === nothing
            final_handler = Handler((req, params) -> HttpResponse(405, "Content-Type: text/plain\r\n", "405 Method Not Allowed"))
        else
            final_handler = handler
        end
        matched_params = matched.params
    end
    
    try
        # Middleware wraps the final handler — middleware can short-circuit
        # (e.g., CORS OPTIONS returns 204 before reaching the handler)
        res = execute_middleware(server.core.middlewares, request.payload, matched_params, final_handler)
        return IdResponse(request.id, res)
    catch e
        @error "Route handler failed to execute" exception=(e, catch_backtrace())
        res = HttpResponse(500, "Content-Type: text/plain\r\n", "500 Internal Server Error")
        return IdResponse(request.id, res)
    end
end
