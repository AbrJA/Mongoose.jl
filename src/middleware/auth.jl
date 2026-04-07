"""
    Authentication middleware — Bearer token and API key authentication.
"""

"""
    BearerToken — Bearer token authentication middleware.
    Checks the `Authorization: Bearer <token>` header and delegates validation to a user-supplied function.
"""
struct BearerToken <: AbstractMiddleware
    validator::Function
end

function (mw::BearerToken)(request::AbstractRequest, params::Vector{Any}, next)
    auth_header = get(request.headers, "authorization", nothing)

    if auth_header === nothing
        return Response(Text, "401 Unauthorized"; status=401, headers=["WWW-Authenticate" => "Bearer"])
    end

    if length(auth_header) < 7 || lowercase(auth_header[1:7]) != "bearer "
        return Response(Text, "401 Unauthorized: Invalid scheme"; status=401, headers=["WWW-Authenticate" => "Bearer"])
    end

    token = auth_header[8:end]

    if !mw.validator(token)
        return Response(Text, "403 Forbidden: Invalid token"; status=403)
    end

    return next()
end

"""
    bearer_token(validator)

Create a Bearer token authentication middleware.
The `validator` function receives the token string and must return `true` if valid.

# Example
```julia
plug!(server, bearer_token(token -> token == "my-secret-token"))
```
"""
bearer_token(validator::Function) = BearerToken(validator)

"""
    ApiKey — API key authentication middleware.
    Reads a header by name and checks it against a set of valid keys.
"""
struct ApiKey <: AbstractMiddleware
    header_name::String
    keys::Set{String}
end

function (mw::ApiKey)(request::AbstractRequest, params::Vector{Any}, next)
    api_key = get(request.headers, mw.header_name, nothing)

    if api_key === nothing || api_key ∉ mw.keys
        return Response(Text, "401 Unauthorized: Invalid API key"; status=401)
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
plug!(server, api_key(keys=Set(["key-123"])))
```
"""
api_key(; header_name::String="X-API-Key", keys::Set{String}) = ApiKey(lowercase(header_name), keys)
