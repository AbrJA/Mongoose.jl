"""
    HTTP Response types — supports buffered and streaming responses.
"""

# --- Buffered Response (most common) ---

"""
    Response — Immutable HTTP response with fully-buffered body.
"""
struct Response
    status::Int
    headers::String
    body::Union{String,Vector{UInt8}}

    Response(status::Int, headers::AbstractString, body::AbstractString) =
        new(status, String(headers), String(body))
    Response(status::Int, headers::AbstractString, body::Vector{UInt8}) =
        new(status, String(headers), body)
end

# --- Ergonomic constructor: status + body with keyword headers ---

"""
    Response(status, body; headers=[])

Create a response with structured headers (auto-serialized).

# Example
```julia
Response(200, "OK"; headers=["X-Custom" => "value"])
```
"""
function Response(status::Int, body::Union{String,Vector{UInt8}};
                  headers::Vector{Pair{String,String}}=Pair{String,String}[])
    hdr = format_headers(headers)
    return Response(status, hdr, body)
end

# --- Typed format constructors ---

function Response(::Type{T}, body; status::Int=200, headers::Vector{Pair{String,String}}=Pair{String,String}[]) where {T<:AbstractFormat}
    rendered = body isa String ? body : encode(T, body)
    hdr = isempty(headers) ? content_type_header(T) : content_type_header(T) * format_headers(headers)
    return Response(status, hdr, rendered)
end

# Plain-text shorthand: Response("hello") or Response("hello"; status=200)
Response(body::AbstractString; status::Int=200, headers::Vector{Pair{String,String}}=Pair{String,String}[]) =
    Response(Plain, body; status=status, headers=headers)

# --- Streaming Response ---

"""
    StreamResponse — Response whose body is produced incrementally.

    The `producer` function receives a `StreamWriter` and writes chunks to it.
    Only supported with `Async` servers (streaming blocks a worker thread).

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
    headers::Vector{Pair{String,String}}
    producer::Function  # (writer::StreamWriter) -> nothing
end

function StreamResponse(producer::Function, status::Int, content_type::String;
                        headers::Vector{Pair{String,String}}=Pair{String,String}[])
    return StreamResponse(status, content_type, headers, producer)
end

# Convenience: StreamResponse(200, "text/event-stream") do writer ... end
function StreamResponse(producer::Function, status::Int=200;
                        content_type::String="application/octet-stream",
                        headers::Vector{Pair{String,String}}=Pair{String,String}[])
    return StreamResponse(status, content_type, headers, producer)
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

function Cookie(name::String, value::String;
                path::String="/", domain::String="",
                max_age::Int=-1, secure::Bool=false,
                httponly::Bool=true, samesite::Symbol=:lax)
    samesite in (:strict, :lax, :none) || error("samesite must be :strict, :lax, or :none")
    return Cookie(name, value, path, domain, max_age, secure, httponly, samesite)
end

function serialize_cookie(c::Cookie)::String
    io = IOBuffer(sizehint=128)
    print(io, c.name, "=", c.value)
    !isempty(c.path) && print(io, "; Path=", c.path)
    !isempty(c.domain) && print(io, "; Domain=", c.domain)
    c.max_age >= 0 && print(io, "; Max-Age=", c.max_age)
    c.secure && print(io, "; Secure")
    c.httponly && print(io, "; HttpOnly")
    c.samesite != :none && print(io, "; SameSite=", titlecase(String(c.samesite)))
    return String(take!(io))
end

# --- Utility: parse cookies from request ---

function parse_cookies(req::Request)::Dict{String,String}
    cookie_header = get(req.headers, "cookie", nothing)
    cookie_header === nothing && return Dict{String,String}()
    return parse_cookie_string(cookie_header)
end

function parse_cookie_string(s::String)::Dict{String,String}
    result = Dict{String,String}()
    for pair in eachsplit(s, ';')
        stripped = strip(pair)
        isempty(stripped) && continue
        eq = findfirst('=', stripped)
        eq === nothing && continue
        k = strip(stripped[1:eq-1])
        v = strip(stripped[eq+1:end])
        result[String(k)] = String(v)
    end
    return result
end
