"""
    CORS (Cross-Origin Resource Sharing) middleware.
    Handles preflight OPTIONS requests and adds CORS headers to all responses.
"""

struct Cors <: Middleware
    headers::String
end

function (mw::Cors)(request::AbstractRequest, params::Vector{Any}, next)
    if request.method === :options
        return Response(204, mw.headers, "")
    end

    response = next()
    if response isa Response
        merged = isempty(response.headers) ? mw.headers : mw.headers * response.headers
        return Response(response.status, merged, response.body)
    end
    return response
end

"""
    cors(; origins, methods, headers, max_age)

Create a CORS middleware.

# Keyword Arguments
- `origins::String`: Allowed origins (default: `"*"`).
- `methods::String`: Allowed HTTP methods (default: `"GET, POST, PUT, PATCH, DELETE, OPTIONS"`).
- `headers::String`: Allowed request headers (default: `"Content-Type, Authorization"`).
- `max_age::Int`: Preflight cache duration in seconds (default: `86400` = 24h).

# Example
```julia
use!(server, cors(origins="https://myapp.com"))
```
"""
function cors(;
    origins::String="*",
    methods::String="GET, POST, PUT, PATCH, DELETE, OPTIONS",
    headers::String="Content-Type, Authorization",
    max_age::Int=86400
)
    cors_headers = string(
        "Access-Control-Allow-Origin: ", origins, "\r\n",
        "Access-Control-Allow-Methods: ", methods, "\r\n",
        "Access-Control-Allow-Headers: ", headers, "\r\n",
        "Access-Control-Max-Age: ", max_age, "\r\n"
    )
    return Cors(cors_headers)
end
