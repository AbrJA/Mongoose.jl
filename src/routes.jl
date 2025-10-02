struct MgRoute
    handlers::Dict{Symbol, Function}
    MgRoute() = new(Dict{Symbol, Function}())
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
    mg_register!(method::Symbol, uri::AbstractString, handler::Function)
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
    method = Symbol(method)
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

# struct Router
#     routes::Dict{String,String}
# end

# # === Global table of routers ===
# const ROUTER_TABLE = Dict{Int, Router}()
# const NEXT_ID = Ref(0)

# # Register router and return a Ptr{Cvoid} handle
# function register_router(router::Router)::Ptr{Cvoid}
#     id = (NEXT_ID[] += 1)
#     ROUTER_TABLE[id] = router
#     return Ptr{Cvoid}(id)   # store integer ID in pointer slot
# end

# # Unregister when no longer needed
# function unregister_router(ptr::Ptr{Cvoid})
#     id = Int(ptr)
#     pop!(ROUTER_TABLE, id, nothing)
# end

# router = Router(Dict("/" => "Hello", "/bye" => "Goodbye"))
# fn_data = register_router(router)
# ROUTER_TABLE