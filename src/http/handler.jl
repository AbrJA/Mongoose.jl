function execute_http_handler(server::Server, request::IdRequest)
    router_obj = server.core.router
    
    if (matched = match_route(router_obj, request.payload.method, request.payload.uri)) === nothing
        res = HttpResponse(404, "Content-Type: text/plain\r\n", "404 Not Found")
        return IdResponse(request.id, res)
    end
    
    if (handler = get(matched.handlers, request.payload.method, nothing)) === nothing
        res = HttpResponse(405, "Content-Type: text/plain\r\n", "405 Method Not Allowed")
        return IdResponse(request.id, res)
    end
    
    try
        # Run middleware pipeline, which eventually calls the handler
        res = execute_middleware(server.core.middlewares, request.payload, matched.params, handler)
        return IdResponse(request.id, res)
    catch e
        @error "Route handler failed to execute" exception=(e, catch_backtrace())
        res = HttpResponse(500, "Content-Type: text/plain\r\n", "500 Internal Server Error")
        return IdResponse(request.id, res)
    end
end
