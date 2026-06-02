"""
    Route groups — hierarchical route organization with scoped middleware.

    Groups provide:
    - Path prefix nesting
    - Scoped middleware (only applies to routes in the group)
    - Clean API for organizing large applications
"""

"""
    RouteGroup — A collection of routes sharing a prefix and middleware stack.
"""
struct RouteGroup
    prefix::String
    middleware::Vector{AbstractMiddleware}
    routes::Vector{Tuple{Symbol,String,Function}}
    ws_routes::Vector{Tuple{String,NamedTuple}}
    children::Vector{RouteGroup}
end

"""
    group(prefix; middleware=[]) → RouteGroup

Create a new route group with the given path prefix.

# Example
```julia
api = group("/api/v1", middleware=[bearer(validate_token)]) do g
    route!(g, :get, "/users", list_users)
    route!(g, :post, "/users", create_user)

    group!(g, "/admin", middleware=[require_role("admin")]) do admin
        route!(admin, :delete, "/users/:id::Int", delete_user)
    end
end
```
"""
function group(f::Function, prefix::String; middleware::Vector{<:AbstractMiddleware}=AbstractMiddleware[])
    g = RouteGroup(
        rstrip(prefix, '/'),
        AbstractMiddleware[middleware...],
        Tuple{Symbol,String,Function}[],
        Tuple{String,NamedTuple}[],
        RouteGroup[]
    )
    f(g)
    return g
end

# Non-block version
function group(prefix::String; middleware::Vector{<:AbstractMiddleware}=AbstractMiddleware[])
    return RouteGroup(
        rstrip(prefix, '/'),
        AbstractMiddleware[middleware...],
        Tuple{Symbol,String,Function}[],
        Tuple{String,NamedTuple}[],
        RouteGroup[]
    )
end

"""
    route!(group, method, path, handler)

Add a route to a group. Path is relative to the group's prefix.
"""
function route!(g::RouteGroup, method::Symbol, path::String, handler::Function)
    push!(g.routes, (method, path, handler))
    return g
end

"""
    ws!(group, path; kwargs...)

Add a WebSocket route to a group.
"""
function ws!(g::RouteGroup, path::String; kwargs...)
    push!(g.ws_routes, (path, values(kwargs)))
    return g
end

# Method helpers for RouteGroup (extend Base where applicable)
Base.get!(g::RouteGroup, path::AbstractString, @nospecialize(h::Function)) = (push!(g.routes, (:get, path, h)); g)
post!(g::RouteGroup, path::AbstractString, @nospecialize(h::Function)) = (push!(g.routes, (:post, path, h)); g)
Base.put!(g::RouteGroup, path::AbstractString, @nospecialize(h::Function)) = (push!(g.routes, (:put, path, h)); g)
patch!(g::RouteGroup, path::AbstractString, @nospecialize(h::Function)) = (push!(g.routes, (:patch, path, h)); g)
Base.delete!(g::RouteGroup, path::AbstractString, @nospecialize(h::Function)) = (push!(g.routes, (:delete, path, h)); g)
options!(g::RouteGroup, path::AbstractString, @nospecialize(h::Function)) = (push!(g.routes, (:options, path, h)); g)
head!(g::RouteGroup, path::AbstractString, @nospecialize(h::Function)) = (push!(g.routes, (:head, path, h)); g)

Base.get!(f::Function, g::RouteGroup, path::AbstractString) = Base.get!(g, path, f)
post!(f::Function, g::RouteGroup, path::AbstractString) = post!(g, path, f)
Base.put!(f::Function, g::RouteGroup, path::AbstractString) = Base.put!(g, path, f)
patch!(f::Function, g::RouteGroup, path::AbstractString) = patch!(g, path, f)
Base.delete!(f::Function, g::RouteGroup, path::AbstractString) = Base.delete!(g, path, f)
options!(f::Function, g::RouteGroup, path::AbstractString) = options!(g, path, f)
head!(f::Function, g::RouteGroup, path::AbstractString) = head!(g, path, f)

"""
    group!(parent, prefix; middleware=[]) do g ... end

Add a nested group to a parent group.
"""
function group!(f::Function, parent::RouteGroup, prefix::String;
                middleware::Vector{<:AbstractMiddleware}=AbstractMiddleware[])
    child = group(f, prefix; middleware=middleware)
    push!(parent.children, child)
    return parent
end

# --- Registration: flatten groups into a Router ---

"""
    route!(router, group)

Register all routes from a group (and its children) into a router.
Middleware from groups is composed with any server-level middleware at dispatch time.
"""
function register_group!(router, g::RouteGroup, parent_prefix::String="",
                         parent_middleware::Vector{AbstractMiddleware}=AbstractMiddleware[])
    mount!(router, g, parent_prefix, parent_middleware)
end

"""
    mount!(router_or_app, group)

Mount a `RouteGroup` into a router or app, registering all its routes with
the group's prefix and middleware applied.

# Example
```julia
api = group("/api/v1") do g
    get!(g, "/users", list_users)
    post!(g, "/users", create_user)
end
mount!(app, api)
```
"""
function mount!(router, g::RouteGroup, parent_prefix::String="",
                parent_middleware::Vector{AbstractMiddleware}=AbstractMiddleware[])
    full_prefix = parent_prefix * g.prefix
    combined_mw = vcat(parent_middleware, g.middleware)

    for (method, path, handler) in g.routes
        full_path = full_prefix * path
        if isempty(combined_mw)
            route!(router, method, full_path, handler)
        else
            wrapped = _wrap_with_middleware(handler, combined_mw)
            route!(router, method, full_path, wrapped)
        end
    end

    for (path, kwargs) in g.ws_routes
        full_path = full_prefix * path
        ws!(router, full_path; kwargs...)
    end

    for child in g.children
        mount!(router, child, full_prefix, combined_mw)
    end
end

"""
    _wrap_with_middleware(handler, middlewares) → Function

Wrap a handler with a middleware stack. The returned function matches
the handler signature expected by the router.
"""
function _wrap_with_middleware(handler::Function, middlewares::Vector{AbstractMiddleware})
    return function(req::AbstractRequest, params...)
        final = (r) -> handler(r, params...)
        execute_pipeline(middlewares, req, final)
    end
end
