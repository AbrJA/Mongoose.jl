struct MgRoute
    handlers::Dict{String, Function}
    MgRoute() = new(Dict{String, Function}())
end

mutable struct MgRouter
    static::Dict{String, MgRoute}
    dynamic::Dict{Regex, MgRoute}
    MgRouter() = new(Dict{String, MgRoute}(), Dict{Regex, MgRoute}())
end

const MG_ROUTER = Ref{MgRouter}()

function mg_global_router()::MgRouter
    if !isassigned(MG_ROUTER)
        MG_ROUTER[] = MgRouter()
    end
    return MG_ROUTER[]
end

# --- 4. Request Handler Registration ---
"""
    mg_register!(method::String, uri::AbstractString, handler::Function)
    Registers an HTTP request handler for a specific method and URI.
    # Arguments
    - `method::AbstractString`: The HTTP method (e.g., GET, POST, PUT, PATCH, DELETE).
    - `uri::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
    - `handler::Function`: The Julia function to be called when a matching request arrives.
    This function should accept a `MgConnection` pointer as its first argument, followed by any additional keyword arguments.
"""
function mg_register!(method::AbstractString, uri::AbstractString, handler::Function)::Nothing
    method = uppercase(method)
    valid_methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    if !(method in valid_methods)
        error("Invalid HTTP method: $method. Valid methods are: $valid_methods")
    end
    router = mg_global_router()
    if occursin(':', uri)
        regex = Regex("^" * replace(uri, r":([a-zA-Z0-9_]+)" => s"(?P<\1>[^/]+)") * "\$")
        if !haskey(router.dynamic, regex)
            router.dynamic[regex] = MgRoute()
        end
        router.dynamic[regex].handlers[method] = handler
    else
        if !haskey(router.static, uri)
            router.static[uri] = MgRoute()
        end
        router.static[uri].handlers[method] = handler
    end
    return
end
