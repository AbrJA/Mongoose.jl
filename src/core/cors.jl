struct Cors <: AbstractMiddleware
    origins::Vector{String}
    allow_credentials::Bool
    allow_methods::String
    allow_headers::String
    max_age::Int
end

@doc """
    Cors — CORS (Cross-Origin Resource Sharing) middleware.

    Handles preflight OPTIONS requests and attaches CORS headers to responses:

    - origin allowlist: only listed origins get `Access-Control-Allow-Origin`,
      reflected verbatim (with `Vary: Origin`); `"*"` still means any origin.
    - credentials: opt-in `Access-Control-Allow-Credentials: true`
      (`"*"` + credentials is not emitted, per the spec).
    - preflight validation: requested method and request headers are checked
      against the allowlists; mismatches get a 403 instead of a blanket 204.
""" Cors

@inline function _origin_allowed(mw::Cors, origin::AbstractString)
    return "*" in mw.origins || origin in mw.origins
end

@inline function _allowed_origin_value(mw::Cors, origin::AbstractString)
    if "*" in mw.origins && !mw.allow_credentials
        return "*"
    end
    return String(origin)
end

function _methods_ok(mw::Cors, requested::AbstractString)
    isempty(requested) && return true
    allowed = [strip(m) for m in split(mw.allow_methods, ','; keepempty=false)]
    return requested in allowed
end

function _headers_ok(mw::Cors, requested::AbstractString)
    isempty(requested) && return true
    requested_headers = split(requested, ','; keepempty=false)
    allowed = [lowercase(strip(h)) for h in split(mw.allow_headers, ','; keepempty=false)]
    all(h -> lowercase(strip(h)) in allowed, requested_headers)
end

function (mw::Cors)(request::Request, next::Function)
    origin = get(request.headers, "origin", nothing)
    allowed = origin !== nothing && _origin_allowed(mw, origin)

    if request.method === :options
        # Preflight
        if !allowed ||
           !_methods_ok(mw, get(request.headers, "access-control-request-method", "")) ||
           !_headers_ok(mw, get(request.headers, "access-control-request-headers", ""))
            return Response(403, Pair{String,String}[], "CORS: preflight rejected")
        end
        headers = Pair{String,String}[
            "Access-Control-Allow-Origin"  => _allowed_origin_value(mw, origin),
            "Access-Control-Allow-Methods" => mw.allow_methods,
            "Access-Control-Allow-Headers" => mw.allow_headers,
            "Access-Control-Max-Age"       => string(mw.max_age),
            "Vary"                         => "Origin",
        ]
        mw.allow_credentials && push!(headers, "Access-Control-Allow-Credentials" => "true")
        return Response(204, headers, "")
    end

    response = next()
    (origin === nothing || !allowed) && return response
    if response isa Response
        headers = Pair{String,String}[
            "Access-Control-Allow-Origin" => _allowed_origin_value(mw, origin),
            "Vary"                        => "Origin",
        ]
        mw.allow_credentials && push!(headers, "Access-Control-Allow-Credentials" => "true")
        return Response(response.status, [headers; response.headers], response.body)
    end
    return response
end

"""
    cors(; origins, methods, headers, max_age, allow_credentials)

Create a CORS middleware. `origins` accepts `"*"`, a single origin, or a
`Vector{String}` of allowed origins.

# Keyword Arguments
- `origins`: Allowed origins (default `"*"`; a list enables per-origin echo).
- `methods::String`: Allowed HTTP methods (default `"GET, POST, PUT, PATCH, DELETE, OPTIONS"`).
- `headers::String`: Allowed request headers (default `"Content-Type, Authorization"`).
- `max_age::Int`: Preflight cache duration in seconds (default `86400`).
- `allow_credentials::Bool`: Emit `Access-Control-Allow-Credentials` (default `false`).

# Example
```julia
use!(app, cors(origins=["https://myapp.com", "https://admin.myapp.com"],
               allow_credentials=true))
```
"""
function cors(;
    origins::Union{String,AbstractVector{String}}="*",
    methods::String="GET, POST, PUT, PATCH, DELETE, OPTIONS",
    headers::String="Content-Type, Authorization",
    max_age::Int=86400,
    allow_credentials::Bool=false
)
    origins_list = origins isa String ? String[origins] : String[origins...]
    return Cors(origins_list, allow_credentials, methods, headers, max_age)
end