struct SecurityHeaders <: AbstractMiddleware
    headers::Vector{Pair{String,String}}
end

@doc """
    SecurityHeaders — adds standard security headers to all responses.

    Protects against common web vulnerabilities (XSS, clickjacking, MIME
    sniffing).
""" SecurityHeaders

function after(mw::SecurityHeaders, ::Request, response)
    response isa Response || return response
    merged = [mw.headers; response.headers]
    return Response(response.status, merged, response.body)
end

"""
    security(; hsts_max_age, frame_options, content_type_options, referrer_policy, csp)

Create a security headers middleware. All headers are pre-computed at construction time.

# Keyword Arguments
- `hsts_max_age::Int`: HSTS max-age in seconds (default: 31536000 = 1 year). Set to 0 to disable.
- `frame_options::String`: X-Frame-Options value (default: "DENY").
- `content_type_options::Bool`: Add X-Content-Type-Options: nosniff (default: true).
- `referrer_policy::String`: Referrer-Policy value (default: "strict-origin-when-cross-origin").
- `csp::String`: Content-Security-Policy value (default: ""). Empty = not added.
"""
function security(;
    hsts_max_age::Int=31536000,
    frame_options::String="DENY",
    content_type_options::Bool=true,
    referrer_policy::String="strict-origin-when-cross-origin",
    csp::String=""
)
    headers = Pair{String,String}[]
    hsts_max_age > 0 && push!(headers, "Strict-Transport-Security" => "max-age=$hsts_max_age; includeSubDomains")
    !isempty(frame_options) && push!(headers, "X-Frame-Options" => frame_options)
    content_type_options && push!(headers, "X-Content-Type-Options" => "nosniff")
    !isempty(referrer_policy) && push!(headers, "Referrer-Policy" => referrer_policy)
    !isempty(csp) && push!(headers, "Content-Security-Policy" => csp)
    return SecurityHeaders(headers)
end
