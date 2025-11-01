struct Route
    handlers::Dict{String, Function}
    Route() = new(Dict{String, Function}())
end

mutable struct Router
    static::Dict{String, Route}
    dynamic::Dict{Regex, Route}
    Router() = new(Dict{String, Route}(), Dict{Regex, Route}())
end

const ROUTER = Ref{Router}()

function global_router()::Router
    if !isassigned(ROUTER)
        ROUTER[] = Router()
    end
    return ROUTER[]
end

# --- 4. Request Handler Registration ---
"""
    register!(method::String, uri::AbstractString, handler::Function)
    Registers an HTTP request handler for a specific method and URI.
    # Arguments
    - `method::AbstractString`: The HTTP method (e.g., GET, POST, PUT, PATCH, DELETE).
    - `uri::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
    - `handler::Function`: The Julia function to be called when a matching request arrives.
    This function should accept a `Request` object as its first argument, followed by any additional keyword arguments.
"""
function register!(method::AbstractString, uri::AbstractString, handler::Function, router::Router = global_router())
    method = uppercase(method)
    valid_methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    if !(method in valid_methods)
        error("Invalid HTTP method: $method. Valid methods are: $valid_methods")
    end
    if occursin(':', uri)
        regex = Regex("^" * replace(uri, r":([a-zA-Z0-9_]+)" => s"(?P<\1>[^/]+)") * "\$")
        if !haskey(router.dynamic, regex)
            router.dynamic[regex] = Route()
        end
        router.dynamic[regex].handlers[method] = handler
    else
        if !haskey(router.static, uri)
            router.static[uri] = Route()
        end
        router.static[uri].handlers[method] = handler
    end
    return
end
