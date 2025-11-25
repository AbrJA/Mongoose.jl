const VALID_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE"]

# --- 4. Request Handler Registration ---
"""
    register!(method::String, uri::AbstractString, handler::Function; server::Server = default_server())
    Registers an HTTP request handler for a specific method and URI.
    # Arguments
    - `handler::Function`: The Julia function to be called when a matching request arrives.
    - `method::AbstractString`: The HTTP method (e.g., GET, POST, PUT, PATCH, DELETE).
    - `uri::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
    - `server::Server = default_server()`: The server to register the handler with.
    This function should accept a `Request` object as its first argument, followed by any additional keyword arguments.
"""
function register!(handler::Function, method::AbstractString, uri::AbstractString; server::Server = default_server())
    method = uppercase(method)
    if !(method in VALID_METHODS)
        error("Invalid HTTP method: $method. Valid methods are: $(VALID_METHODS)")
    end
    if occursin(':', uri)
        regex = Regex('^' * replace(uri, r":([a-zA-Z0-9_]+)" => s"(?P<\1>[^/]+)") * '\$')
        if !haskey(server.router.dynamic, regex)
            server.router.dynamic[regex] = Route()
        end
        server.router.dynamic[regex].handlers[method] = handler
    else
        if !haskey(server.router.static, uri)
            server.router.static[uri] = Route()
        end
        server.router.static[uri].handlers[method] = handler
    end
    return
end

function dispatch(route::Route, request::IdRequest; kwargs...)
    method = request.payload.method
    if haskey(route.handlers, method)
            try
                response = route.handlers[method](request.payload; kwargs...)
                return IdResponse(request.id, response)
            catch e # CHECK THIS TO ALWAYS RESPOND
                @error "Route handler failed to execute" exception = (e, catch_backtrace())
                response = Response(500, Dict("Content-Type" => "text/plain"), "500 Internal Server Error")
                return IdResponse(request.id, response)
            end
    else
        response = Response(405, Dict("Content-Type" => "text/plain"), "405 Method Not Allowed")
        return IdResponse(request.id, response)
    end
end

# mutable struct Responses
#     not_found::Response
#     not_allowed::Response
#     internal_error::Response
#     function Responses(not_found::Response = Response(404, Dict("Content-Type" => "text/plain"), "404 Not Found"),
#                        not_allowed::Response = Response(405, Dict("Content-Type" => "text/plain"), "405 Method Not Allowed"),
#                        internal_error::Response = Response(500, Dict("Content-Type" => "text/plain"), "500 Internal Server Error"))
#         new(not_found, not_allowed, internal_error)
#     end
# end

# const RESPONSES = Ref{Responses}()

# function default_responses()
#     isassigned(RESPONSES) || (RESPONSES[] = Responses())
#     return RESPONSES[]
# end

# Change this to match_route
function handle(router::Router, request::IdRequest)
    if (route = get(router.static, request.payload.uri, nothing)) !== nothing
        response = dispatch(route, request)
        return response
    end
    for (regex, route) in router.dynamic
        if (m = match(regex, request.payload.uri)) !== nothing
            response = dispatch(route, request; params = m)
            return response
        end
    end
    response = Response(404, Dict("Content-Type" => "text/plain"), "404 Not Found")
    return IdResponse(request.id, response)
end

function resolve(conn::MgConnection, server::SyncServer, request::IdRequest)
    response = handle(server.router, request)
    mg_http_reply(conn, response.payload.status, to_string(response.payload.headers), response.payload.body)
    return
end

function resolve(conn::MgConnection, server::AsyncServer, request::IdRequest)
    server.connections[request.id] = conn
    put!(server.requests, request)
    return
end

function cancel(conn::MgConnection, server::AsyncServer)
    delete!(server.connections, Int(conn))
    return
end

function cancel(::MgConnection, ::SyncServer)
    return
end
