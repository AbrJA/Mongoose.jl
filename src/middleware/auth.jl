"""
    Authentication middleware — Bearer token and API key authentication.
"""

"""
    Bearer — Bearer token authentication middleware.
    Checks the `Authorization: Bearer <token>` header and delegates validation to a user-supplied function.
"""
struct Bearer <: AbstractMiddleware
    validator::Function
end

function (mw::Bearer)(request::AbstractRequest, params::Vector{Any}, next)
    auth_header = get(request.headers, "authorization", nothing)

    if auth_header === nothing
        return Response(Plain, "401 Unauthorized"; status=401, headers=["WWW-Authenticate" => "Bearer"])
    end

    if length(auth_header) < 7 || !_isbearer(auth_header)
        return Response(Plain, "401 Unauthorized: Invalid scheme"; status=401, headers=["WWW-Authenticate" => "Bearer"])
    end

    token = auth_header[8:end]

    if !mw.validator(token)
        return Response(Plain, "403 Forbidden: Invalid token"; status=403)
    end

    return next()
end

"""
    _isbearer(s) → Bool

Case-insensitive, zero-allocation check that `s` starts with `"bearer "`.
"""
@inline function _isbearer(s::AbstractString)::Bool
    _tolower(codeunit(s, 1)) == UInt8('b') || return false
    _tolower(codeunit(s, 2)) == UInt8('e') || return false
    _tolower(codeunit(s, 3)) == UInt8('a') || return false
    _tolower(codeunit(s, 4)) == UInt8('r') || return false
    _tolower(codeunit(s, 5)) == UInt8('e') || return false
    _tolower(codeunit(s, 6)) == UInt8('r') || return false
    codeunit(s, 7) == UInt8(' ') || return false
    return true
end

"""
    bearer(validator)

Create a Bearer token authentication middleware.
The `validator` function receives the token string and must return `true` if valid.

# Example
```julia
plug!(server, bearer(token -> token == "my-secret-token"))
```
"""
bearer(validator::Function) = Bearer(validator)

"""
    ApiKey — API key authentication middleware.
    Reads a header by name and checks it against a set of valid keys.
"""
struct ApiKey <: AbstractMiddleware
    header_name::String
    keys::Set{String}
end

function (mw::ApiKey)(request::AbstractRequest, params::Vector{Any}, next)
    apikey = get(request.headers, mw.header_name, nothing)

    if apikey === nothing || apikey ∉ mw.keys
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
plug!(server, apikey(keys=Set(["key-123"])))
```
"""
apikey(; header_name::String="X-API-Key", keys::Set{String}) = ApiKey(lowercase(header_name), keys)
