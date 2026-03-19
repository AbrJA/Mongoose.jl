"""
    CORS (Cross-Origin Resource Sharing) middleware.
    Handles preflight OPTIONS requests and adds CORS headers to all responses.
"""

"""
    cors_middleware(; origins, methods, headers, max_age)

Create a CORS middleware function.

# Keyword Arguments
- `origins::String`: Allowed origins (default: `"*"`).
- `methods::String`: Allowed HTTP methods (default: `"GET, POST, PUT, PATCH, DELETE, OPTIONS"`).
- `headers::String`: Allowed request headers (default: `"Content-Type, Authorization"`).
- `max_age::Int`: Preflight cache duration in seconds (default: `86400` = 24h).

# Example
```julia
use!(server, cors_middleware(origins="https://myapp.com"))
```
"""
function cors_middleware(;
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

    return function(request::AbstractRequest, params::Dict{String,String}, next)
        # Handle preflight OPTIONS
        if request.method === :options
            return HttpResponse(204, cors_headers, "")
        end

        # Call next and add CORS headers to response
        response = next()
        if response isa HttpResponse
            merged = if isempty(response.headers)
                cors_headers
            else
                cors_headers * response.headers
            end
            return HttpResponse(response.status, merged, response.body)
        end
        return response
    end
end
