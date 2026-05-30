"""
    Content format types and MIME negotiation.

    Each format is a singleton type dispatched via Julia's type system for
    zero-cost content-type resolution. Users can extend by subtyping `AbstractFormat`.
"""
abstract type AbstractFormat end

struct Plain <: AbstractFormat end
struct Html <: AbstractFormat end
struct Css <: AbstractFormat end
struct Js <: AbstractFormat end
struct Json <: AbstractFormat end
struct Xml <: AbstractFormat end
struct Binary <: AbstractFormat end

# --- MIME type resolution (extensible via dispatch) ---

mime(::Type{Plain})  = "text/plain; charset=utf-8"
mime(::Type{Html})   = "text/html; charset=utf-8"
mime(::Type{Css})    = "text/css; charset=utf-8"
mime(::Type{Js})     = "application/javascript; charset=utf-8"
mime(::Type{Json})   = "application/json; charset=utf-8"
mime(::Type{Xml})    = "application/xml; charset=utf-8"
mime(::Type{Binary}) = "application/octet-stream"
mime(::Type{T}) where {T<:AbstractFormat} = error("MIME type not defined for format $T. Implement `Mongoose.mime(::Type{$T})`.")

# --- Pre-computed Content-Type header strings (hot path) ---

const _CONTENT_HEADERS = Dict{DataType,String}(
    Plain  => "Content-Type: text/plain; charset=utf-8\r\n",
    Html   => "Content-Type: text/html; charset=utf-8\r\n",
    Css    => "Content-Type: text/css; charset=utf-8\r\n",
    Js     => "Content-Type: application/javascript; charset=utf-8\r\n",
    Json   => "Content-Type: application/json; charset=utf-8\r\n",
    Xml    => "Content-Type: application/xml; charset=utf-8\r\n",
    Binary => "Content-Type: application/octet-stream\r\n",
)

@inline function content_type_header(::Type{T})::String where {T<:AbstractFormat}
    return get(_CONTENT_HEADERS, T) do
        string("Content-Type: ", mime(T), "\r\n")
    end
end

# --- Body encoding (extensible via dispatch) ---

encode(::Type{T}, body) where {T<:AbstractFormat} = error("encode not implemented for $T with body::$(typeof(body)). Implement `Mongoose.encode(::Type{$T}, body)`.")
encode(::Type{T}, body::String) where {T<:AbstractFormat} = body
encode(::Type{Binary}, body::Vector{UInt8}) = body
