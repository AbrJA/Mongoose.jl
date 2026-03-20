"""
    Authentication middleware — Bearer token and API key authentication.
"""

"""
    auth_bearer(validator)

Create a Bearer token authentication middleware.
The `validator` function receives the token string and must return `true` if valid.

Extracts the token from the `Authorization: Bearer <token>` header.
Returns 401 Unauthorized if missing or invalid.

# Example
```julia
use!(server, auth_bearer(token -> token == "my-secret-token"))
```
"""
function auth_bearer(validator::Function)
    return function(request::AbstractRequest, params::Vector{Any}, next)
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

        token = auth_header[8:end]  # Skip "Bearer "

        if !validator(token)
            return Response(403, "Content-Type: text/plain\r\n", "403 Forbidden: Invalid token")
        end

        return next()
    end
end

"""
    auth_api_key(; header_name, keys)

Create an API key authentication middleware.
Checks for a valid key in the specified request header.

# Keyword Arguments
- `header_name::String`: Header to read the API key from (default: `"X-API-Key"`).
- `keys::Set{String}`: Set of valid API keys.

# Example
```julia
valid_keys = Set(["key-123", "key-456"])
use!(server, auth_api_key(keys=valid_keys))
```
"""
function auth_api_key(; header_name::String="X-API-Key", keys::Set{String})
    header_name_lower = lowercase(header_name)
    return function(request::AbstractRequest, params::Vector{Any}, next)
        api_key = if request isa Request
            get(request.headers, header_name_lower, nothing)
        elseif request isa ViewRequest
            header(request, header_name)
        else
            nothing
        end

        if api_key === nothing || api_key ∉ keys
            return Response(401, "Content-Type: text/plain\r\n", "401 Unauthorized: Invalid API key")
        end

        return next()
    end
end
