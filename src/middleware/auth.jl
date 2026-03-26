"""
    Authentication middleware — Bearer token and API key authentication.
"""

struct BearerAuth <: AbstractMiddleware
    validator::Function
end

function (mw::BearerAuth)(request::AbstractRequest, params::Vector{Any}, next)
    auth_header = header(request, "Authorization")

    if auth_header === nothing
        return Response(401, ContentType.text * "WWW-Authenticate: Bearer\r\n", "401 Unauthorized")
    end

    if !startswith(auth_header, "Bearer ")
        return Response(401, ContentType.text * "WWW-Authenticate: Bearer\r\n", "401 Unauthorized: Invalid scheme")
    end

    token = auth_header[8:end]

    if !mw.validator(token)
        return Response(403, ContentType.text, "403 Forbidden: Invalid token")
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

struct ApiKeyAuth <: AbstractMiddleware
    header_name::String
    keys::Set{String}
end

function (mw::ApiKeyAuth)(request::AbstractRequest, params::Vector{Any}, next)
    api_key = header(request, mw.header_name)

    if api_key === nothing || api_key ∉ mw.keys
        return Response(401, ContentType.text, "401 Unauthorized: Invalid API key")
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
auth_api_key(; header_name::String="X-API-Key", keys::Set{String}) = ApiKeyAuth(header_name, keys)
