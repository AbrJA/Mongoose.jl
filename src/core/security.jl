struct Security <: AbstractMiddleware
    headers::Vector{Pair{String,String}}
end

@doc """
    Security — adds standard security headers to all responses.

    Protects against common web vulnerabilities (XSS, clickjacking, MIME
    sniffing).
""" Security

function (mw::Security)(request::Request, next::Function)
    response = next()
    response isa Response || return response
    return mergeheaders(response, mw.headers; prepend=true)
end

"""
    security(; hsts_max_age_seconds, frame_options, content_type_options, referrer_policy, csp)

Create a security headers middleware. All headers are pre-computed at
construction time. Each optional header is disabled with `nothing` (uniform
"off" convention); only `content_type_options` is a plain `Bool`.

# Keyword Arguments
- `hsts_max_age_seconds::Union{Nothing,Int}`: HSTS max-age in seconds
  (default: 31536000 = 1 year). `nothing` disables the header.
- `frame_options::Union{Nothing,String}`: X-Frame-Options value (default: "DENY").
- `content_type_options::Bool`: Add X-Content-Type-Options: nosniff (default: true).
- `referrer_policy::Union{Nothing,String}`: Referrer-Policy value (default: "strict-origin-when-cross-origin").
- `csp::Union{Nothing,String}`: Content-Security-Policy value (default: nothing = not added).
"""
function security(;
    hsts_max_age_seconds::Union{Nothing,Int}=31536000,
    frame_options::Union{Nothing,String}="DENY",
    content_type_options::Bool=true,
    referrer_policy::Union{Nothing,String}="strict-origin-when-cross-origin",
    csp::Union{Nothing,String}=nothing
)
    headers = Pair{String,String}[]
    hsts_max_age_seconds !== nothing &&
        push!(headers, "Strict-Transport-Security" => "max-age=$hsts_max_age_seconds; includeSubDomains")
    frame_options !== nothing && push!(headers, "X-Frame-Options" => frame_options)
    content_type_options && push!(headers, "X-Content-Type-Options" => "nosniff")
    referrer_policy !== nothing && push!(headers, "Referrer-Policy" => referrer_policy)
    csp !== nothing && push!(headers, "Content-Security-Policy" => csp)
    return Security(headers)
end
