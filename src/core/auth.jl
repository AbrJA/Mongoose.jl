"""
    Authentication middleware — Bearer token and API key authentication.
"""

# Constant-time string comparison to prevent timing attacks
@noinline function _constant_time_eq(a::AbstractString, b::AbstractString)::Bool
    a_bytes = codeunits(a)
    b_bytes = codeunits(b)
    length(a_bytes) == length(b_bytes) || return false
    result = UInt8(0)
    @inbounds for i in eachindex(a_bytes)
        result |= a_bytes[i] ⊻ b_bytes[i]
    end
    return result == 0
end

"""
    Bearer — Bearer token authentication middleware.
    Checks the `Authorization: Bearer <token>` header and delegates validation to a user-supplied function.
"""
struct Bearer <: AbstractMiddleware
    validator::Function
end

function (mw::Bearer)(request::Request, next::Function)
    auth_header = get(request.headers, "authorization", nothing)

    if auth_header === nothing
        return Response(Plain, "401 Unauthorized"; status=401, headers=["WWW-Authenticate" => "Bearer"])
    end

    if length(auth_header) < 8 || !startswith(lowercase(auth_header), "bearer ")
        return Response(Plain, "401 Unauthorized: Invalid scheme"; status=401, headers=["WWW-Authenticate" => "Bearer"])
    end

    token = auth_header[8:end]

    if !mw.validator(token)
        return Response(Plain, "403 Forbidden: Invalid token"; status=403)
    end

    return next()
end

"""
    bearer(validator)
    bearer(secret::String)

Create a Bearer token authentication middleware.
When called with a function, `validator(token)` must return `true` if valid.
When called with a string, uses constant-time comparison to prevent timing attacks.

# Example
```julia
use!(server, bearer("my-secret-token"))
use!(server, bearer(token -> token in valid_tokens))
```
"""
bearer(validator::Function) = Bearer(validator)
bearer(secret::String) = Bearer(token -> _constant_time_eq(token, secret))

"""
    ApiKey — API key authentication middleware.
    Reads a header by name and checks it against a set of valid keys.
"""
struct ApiKey <: AbstractMiddleware
    header_name::String
    keys::Set{String}
end

function (mw::ApiKey)(request::Request, next::Function)
    apikey = get(request.headers, mw.header_name, nothing)

    if apikey === nothing || !any(k -> _constant_time_eq(apikey, k), mw.keys)
        return Response(Plain, "401 Unauthorized: Invalid API key"; status=401)
    end

    return next()
end

"""
    apikey(; header_name, keys)

Create an API key authentication middleware.

# Keyword Arguments
- `header_name::String`: Header to read the API key from (default: `"X-API-Key"`).
- `keys::Set{String}`: Set of valid API keys.

# Example
```julia
use!(server, apikey(keys=Set(["key-123"])))
```
"""
apikey(; header_name::String="X-API-Key", keys::Set{String}) = ApiKey(lowercase(header_name), keys)
