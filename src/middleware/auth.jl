"""
    Authentication middleware — Bearer token and API key authentication.
"""

struct BearerAuth <: Middleware
    validator::Function
end

function (mw::BearerAuth)(request::AbstractRequest, params::Vector{Any}, next)
    auth_header = if request isa Request
        get(request.headers, "authorization", nothing)
    elseif request isa ViewRequest
        header(request, "Authorization")
    else
        nothing
    end

    if auth_header === nothing
        return Response(401, "Content-Type: text/plain\r\nWWW-Authenticate: Bearer\r\n", "401 Unauthorized")
    end

    if !startswith(auth_header, "Bearer ")
        return Response(401, "Content-Type: text/plain\r\nWWW-Authenticate: Bearer\r\n", "401 Unauthorized: Invalid scheme")
    end

    token = auth_header[8:end]

    if !mw.validator(token)
        return Response(403, "Content-Type: text/plain\r\n", "403 Forbidden: Invalid token")
    end

    return next()
end

"""
    auth_bearer(validator)

Create a Bearer token authentication middleware.
The `validator` function receives the token string and must return `true` if valid.

# Example
```julia
use!(server, auth_bearer(token -> token == "my-secret-token"))
```
"""
auth_bearer(validator::Function) = BearerAuth(validator)

struct ApiKeyAuth <: Middleware
    header_name::String
    header_name_lower::String
    keys::Set{String}
end

function (mw::ApiKeyAuth)(request::AbstractRequest, params::Vector{Any}, next)
    api_key = if request isa Request
        get(request.headers, mw.header_name_lower, nothing)
    elseif request isa ViewRequest
        header(request, mw.header_name)
    else
        nothing
    end

    if api_key === nothing || api_key ∉ mw.keys
        return Response(401, "Content-Type: text/plain\r\n", "401 Unauthorized: Invalid API key")
    end

    return next()
end

"""
    auth_api_key(; header_name, keys)

Create an API key authentication middleware.

# Keyword Arguments
- `header_name::String`: Header to read the API key from (default: `"X-API-Key"`).
- `keys::Set{String}`: Set of valid API keys.

# Example
```julia
use!(server, auth_api_key(keys=Set(["key-123"])))
```
"""
auth_api_key(; header_name::String="X-API-Key", keys::Set{String}) = ApiKeyAuth(header_name, lowercase(header_name), keys)
