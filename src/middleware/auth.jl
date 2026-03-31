"""
    Authentication middleware — Bearer token and API key authentication.
"""

struct BearerToken <: AbstractMiddleware
    validator::Function
end

function (mw::BearerToken)(request::AbstractRequest, params::Vector{Any}, next)
    auth_header = get(request.headers, "Authorization", nothing)

    if auth_header === nothing
        return Response(401, ContentType.text * "WWW-Authenticate: Bearer\r\n", "401 Unauthorized")
    end

    if length(auth_header) < 7 || lowercase(auth_header[1:7]) != "bearer "
        return Response(401, ContentType.text * "WWW-Authenticate: Bearer\r\n", "401 Unauthorized: Invalid scheme")
    end

    token = auth_header[8:end]

    if !mw.validator(token)
        return Response(403, ContentType.text, "403 Forbidden: Invalid token")
    end

    return next()
end

"""
    bearer_token(validator)

Create a Bearer token authentication middleware.
The `validator` function receives the token string and must return `true` if valid.

# Example
```julia
use!(server, bearer_token(token -> token == "my-secret-token"))
```
"""
bearer_token(validator::Function) = BearerToken(validator)

struct ApiKey <: AbstractMiddleware
    header_name::String
    keys::Set{String}
end

function (mw::ApiKey)(request::AbstractRequest, params::Vector{Any}, next)
    api_key = get(request.headers, mw.header_name, nothing)

    if api_key === nothing || api_key ∉ mw.keys
        return Response(401, ContentType.text, "401 Unauthorized: Invalid API key")
    end

    return next()
end

"""
    api_key(; header_name, keys)

Create an API key authentication middleware.

# Keyword Arguments
- `header_name::String`: Header to read the API key from (default: `"X-API-Key"`).
- `keys::Set{String}`: Set of valid API keys.

# Example
```julia
use!(server, api_key(keys=Set(["key-123"])))
```
"""
api_key(; header_name::String="X-API-Key", keys::Set{String}) = ApiKey(lowercase(header_name), keys)
