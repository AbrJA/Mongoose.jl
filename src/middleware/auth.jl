"""
    Authentication middleware — Bearer token and API key authentication.
"""

"""
    bearer_auth_middleware(validator)

Create a Bearer token authentication middleware.
The `validator` function receives the token string and must return `true` if valid.

Extracts the token from the `Authorization: Bearer <token>` header.
Returns 401 Unauthorized if missing or invalid.

# Example
```julia
use!(server, bearer_auth_middleware(token -> token == "my-secret-token"))
```
"""
function bearer_auth_middleware(validator::Function)
    return function(request::AbstractRequest, params::Dict{String,String}, next)
        auth_header = if request isa HttpRequest
            get(request.headers, "authorization", nothing)
        elseif request isa ViewRequest
            header(request, "Authorization")
        else
            nothing
        end

        if auth_header === nothing
            return HttpResponse(401, "Content-Type: text/plain\r\nWWW-Authenticate: Bearer\r\n", "401 Unauthorized")
        end

        if !startswith(auth_header, "Bearer ")
            return HttpResponse(401, "Content-Type: text/plain\r\nWWW-Authenticate: Bearer\r\n", "401 Unauthorized: Invalid scheme")
        end

        token = auth_header[8:end]  # Skip "Bearer "

        if !validator(token)
            return HttpResponse(403, "Content-Type: text/plain\r\n", "403 Forbidden: Invalid token")
        end

        return next()
    end
end

"""
    api_key_middleware(; header_name, keys)

Create an API key authentication middleware.
Checks for a valid key in the specified request header.

# Keyword Arguments
- `header_name::String`: Header to read the API key from (default: `"X-API-Key"`).
- `keys::Set{String}`: Set of valid API keys.

# Example
```julia
valid_keys = Set(["key-123", "key-456"])
use!(server, api_key_middleware(keys=valid_keys))
```
"""
function api_key_middleware(; header_name::String="X-API-Key", keys::Set{String})
    header_name_lower = lowercase(header_name)
    return function(request::AbstractRequest, params::Dict{String,String}, next)
        api_key = if request isa HttpRequest
            get(request.headers, header_name_lower, nothing)
        elseif request isa ViewRequest
            header(request, header_name)
        else
            nothing
        end

        if api_key === nothing || api_key ∉ keys
            return HttpResponse(401, "Content-Type: text/plain\r\n", "401 Unauthorized: Invalid API key")
        end

        return next()
    end
end
