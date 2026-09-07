"""
    CORS (Cross-Origin Resource Sharing) middleware.
    Handles preflight OPTIONS requests and adds CORS headers to all responses.
"""

struct Cors <: AbstractMiddleware
    headers::Vector{Pair{String,String}}
end

function (mw::Cors)(request::Request, next::Function)
    if request.method === :options
        return Response(204, mw.headers, "")
    end

    response = next()
    if response isa Response
        merged = [mw.headers; response.headers]
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
use!(app, cors(origins="https://myapp.com"))
```
"""
function cors(;
    origins::String="*",
    methods::String="GET, POST, PUT, PATCH, DELETE, OPTIONS",
    headers::String="Content-Type, Authorization",
    max_age::Int=86400
)
    cors_headers = Pair{String,String}[
        "Access-Control-Allow-Origin"  => origins,
        "Access-Control-Allow-Methods" => methods,
        "Access-Control-Allow-Headers" => headers,
        "Access-Control-Max-Age"       => string(max_age),
    ]
    return Cors(cors_headers)
end
