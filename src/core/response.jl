"""
    HTTP Response types — supports buffered and streaming responses.
"""

# --- Buffered Response (most common) ---

"""
    Response — Immutable HTTP response with structured headers.

    Headers are stored as a `Vector{Pair{String,String}}` and serialized
    to wire format only when sent. Middleware can inspect and modify headers
    before they reach the client.
"""
struct Response
    status::Int
    headers::Headers
    body::Union{String,Vector{UInt8}}

    Response(status::Int, headers::Headers, body::AbstractString) =
        new(status, headers, String(body))
    Response(status::Int, headers::Headers, body::AbstractVector{UInt8}) =
        new(status, headers, Vector{UInt8}(body))
    Response(status::Int, headers::Vector{Pair{String,String}}, body::AbstractString) =
        new(status, Headers(headers), String(body))
    Response(status::Int, headers::Vector{Pair{String,String}}, body::AbstractVector{UInt8}) =
        new(status, Headers(headers), Vector{UInt8}(body))
end

Base.:(==)(a::Response, b::Response) =
    a.status == b.status && a.headers == b.headers && a.body == b.body

# --- Non-mutating header merging ---

"""
    mergeheaders(headers::Headers, extra; prepend=false) → Headers
    mergeheaders(response::Response, extra; prepend=false) → Response

Return a new headers list (or a new `Response` carrying it) with `extra`
merged in; the original is left untouched. `extra` may be a single pair or a
vector of pairs.

This is a concatenation, not a dictionary merge: existing pairs are preserved
(including duplicates and order). `extra` is appended after them by default;
`prepend=true` places `extra` first so `get`/`haskey` find those values before
any same-named pair the original carried.
"""
@inline function mergeheaders(h::Headers, extra::Pair{String,String};
                              prepend::Bool=false)
    return mergeheaders(h, [extra]; prepend=prepend)
end

@inline function mergeheaders(h::Headers, extra::AbstractVector{<:Pair{String,String}};
                              prepend::Bool=false)
    n, m = length(h.data), length(extra)
    merged = Vector{Pair{String,String}}(undef, n + m)
    if prepend
        copyto!(merged, 1, extra, 1, m)
        copyto!(merged, m + 1, h.data, 1, n)
    else
        copyto!(merged, 1, h.data, 1, n)
        copyto!(merged, n + 1, extra, 1, m)
    end
    return Headers(merged)
end

@inline function mergeheaders(res::Response,
                              extra::Union{Pair{String,String},AbstractVector{<:Pair{String,String}}};
                              prepend::Bool=false)
    return Response(res.status, mergeheaders(res.headers, extra; prepend=prepend), res.body)
end

# --- Primary ergonomic constructor: status + body ---

"""
    Response(status, body; headers=[]) → Response

Create a plain-text response.

# Example
```julia
Response(200, "OK")
Response(404, "Not Found"; headers=["X-Custom" => "value"])
```
"""
function Response(status::Int, body::Union{String,Vector{UInt8}};
                  headers=Headers())
    h = asheaders(headers)
    # Keep bare responses consistent with `text()`/`Response(Plain, …)`:
    # a non-empty body gets a default Content-Type unless one is provided.
    if !isempty(body) && !haskey(h, "content-type")
        h = mergeheaders(h, [contenttypepair(Plain)])
    end
    return Response(status, h, body)
end

# --- Typed format constructors ---

"""
    Response(Format, body; status=200, headers=[]) → Response

Create a response with automatic Content-Type for the given format.

# Example
```julia
Response(Json, Dict("ok" => true))
Response(Html, "<h1>Hello</h1>"; status=200)
```
"""
function Response(::Type{T}, body; status::Int=200,
                  headers=Headers()) where {T<:AbstractFormat}
    rendered = body isa String ? body : encode(T, body)
    merged = mergeheaders(asheaders(headers), [contenttypepair(T)]; prepend=true)
    return Response(status, merged, rendered)
end

# Plain-text shorthand: Response("hello") or Response("hello"; status=200)
Response(body::AbstractString; status::Int=200, headers=Headers()) =
    Response(Plain, body; status=status, headers=headers)

# --- Response Helpers (FastAPI-style) ---

"""
    json(data; status=200, headers=[]) → Response

Create a JSON response. Supports Dict, NamedTuple, Vector, and any JSON-serializable type.

# Example
```julia
json(Dict("id" => 1, "name" => "Alice"))
json((id=1, name="Alice"))  # NamedTuple
json(Dict("error" => "Not Found"); status=404)
```
"""
function json(data; status::Int=200, headers=Headers())
    return Response(Json, data; status=status, headers=headers)
end

"""
    parsejson(req) → Any

Parse the request body as JSON. Throws `BadRequestError` (400) on malformed
JSON so the pipeline answers 400 instead of falling through to a 500.
"""
function parsejson(req::Request)
    return try
        decode(Json, req.body)
    catch e
        throw(BadRequestError("Invalid JSON body: $(sprint(showerror, e))"))
    end
end

# `json(req)` used to parse the body; it now dispatches to the serializer,
# which would silently produce nonsense. Fail loudly instead.
json(::Request) = throw(ArgumentError(
    "json(req) no longer parses request bodies — use parsejson(req) for parsing and json(data) for responses"))

"""
    html(content; status=200, headers=[]) → Response
"""
html(content; status::Int=200, headers=Headers()) =
    Response(Html, content; status=status, headers=headers)

"""
    text(content; status=200, headers=[]) → Response
"""
text(content; status::Int=200, headers=Headers()) =
    Response(Plain, content; status=status, headers=headers)

"""
    redirect(url; status=302, headers=[]) → Response

Return an HTTP redirect response.

# Example
```julia
redirect("/login")
redirect("https://example.com"; status=301)
```
"""
function redirect(url::AbstractString; status::Int=302, headers=Headers())
    _has_ctl(url) && throw(ArgumentError("redirect URL contains control characters"))
    return Response(status, mergeheaders(asheaders(headers), ["Location" => String(url)]), "")
end

# --- Streaming Response ---

"""
    StreamResponse — Response whose body is produced incrementally.

    The `producer` function receives a `StreamWriter` and writes chunks to it.
    The producer runs on its own task, feeding a bounded channel that the
    event loop drains — a slow producer never blocks the poll thread or other
    connections. Works in both sync and async modes.

    # Example
    ```julia
    function sse_handler(req)
        StreamResponse(200, "text/event-stream") do writer
            for i in 1:10
                write(writer, "data: event \$i\\n\\n")
                flush(writer)
                sleep(0.5)
            end
        end
    end
    ```
"""
struct StreamResponse
    status::Int
    content_type::String
    headers::Headers
    producer::Function  # (writer::StreamWriter) -> nothing
end

function StreamResponse(producer::Function, status::Int, content_type::String;
                        headers=Headers())
    return StreamResponse(status, content_type, asheaders(headers), producer)
end

# Convenience: StreamResponse(200, "text/event-stream") do writer ... end
function StreamResponse(producer::Function, status::Int=200;
                        content_type::String="application/octet-stream",
                        headers=Headers())
    return StreamResponse(status, content_type, asheaders(headers), producer)
end

# --- Cookie support in responses ---

"""
    Cookie — HTTP Set-Cookie parameters.
"""
struct Cookie
    name::String
    value::String
    path::String
    domain::String
    max_age::Int          # seconds, -1 = session cookie
    secure::Bool
    httponly::Bool
    samesite::Symbol      # :strict, :lax, :none
end

# CRLF/control-character guard for values that end up in response headers
# (Set-Cookie fields, Location). Prevents response splitting.
@inline function _has_ctl(s::AbstractString)::Bool
    for c in s
        (c == '\r' || c == '\n' || c < ' ') && return true
    end
    return false
end

function Cookie(name::String, value::String;
                path::String="/", domain::String="",
                max_age::Int=-1, secure::Bool=false,
                httponly::Bool=true, samesite::Symbol=:lax)
    samesite in (:strict, :lax, :none) || error("samesite must be :strict, :lax, or :none")
    _has_ctl(name) && throw(ArgumentError("Cookie name contains control characters"))
    _has_ctl(value) && throw(ArgumentError("Cookie value contains control characters"))
    _has_ctl(path) && throw(ArgumentError("Cookie path contains control characters"))
    _has_ctl(domain) && throw(ArgumentError("Cookie domain contains control characters"))
    return Cookie(name, value, path, domain, max_age, secure, httponly, samesite)
end

"""
    setcookie(cookie) → String

Serialize a `Cookie` to a `Set-Cookie` header value string.
"""
function setcookie(c::Cookie)::String
    # Defense in depth: the positional `Cookie` constructor bypasses the
    # keyword validation, so re-check before serializing to a header.
    (_has_ctl(c.name) || _has_ctl(c.value) || _has_ctl(c.path) || _has_ctl(c.domain)) &&
        throw(ArgumentError("Cookie fields contain control characters"))
    io = IOBuffer(sizehint=128)
    print(io, c.name, "=", c.value)
    !isempty(c.path) && print(io, "; Path=", c.path)
    !isempty(c.domain) && print(io, "; Domain=", c.domain)
    c.max_age >= 0 && print(io, "; Max-Age=", c.max_age)
    c.secure && print(io, "; Secure")
    c.httponly && print(io, "; HttpOnly")
    print(io, "; SameSite=", titlecase(String(c.samesite)))
    return String(take!(io))
end

# --- Utility: parse cookies from request ---

"""
    parsecookies(req) → Dict{String,String}

Parse cookies from the request `Cookie` header.
"""
function parsecookies(req::Request)::Dict{String,String}
    cookie_header = get(req.headers, "cookie", nothing)
    cookie_header === nothing && return Dict{String,String}()
    return _parse_cookie_string(cookie_header)
end

function _parse_cookie_string(s::String)::Dict{String,String}
    result = Dict{String,String}()
    for pair in eachsplit(s, ';')
        stripped = strip(pair)
        isempty(stripped) && continue
        eq = findfirst('=', stripped)
        eq === nothing && continue
        # `findfirst` returns a byte index; slice on character boundaries so
        # multibyte cookie values cannot throw StringIndexError.
        k = strip(stripped[1:prevind(stripped, eq)])
        v = strip(stripped[nextind(stripped, eq):end])
        result[String(k)] = String(v)
    end
    return result
end
