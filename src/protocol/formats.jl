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

# --- Pre-computed Content-Type header pairs (structured, zero-alloc on hot path) ---

const _CONTENT_PAIRS = Dict{DataType,Pair{String,String}}(
    Plain  => "Content-Type" => "text/plain; charset=utf-8",
    Html   => "Content-Type" => "text/html; charset=utf-8",
    Css    => "Content-Type" => "text/css; charset=utf-8",
    Js     => "Content-Type" => "application/javascript; charset=utf-8",
    Json   => "Content-Type" => "application/json; charset=utf-8",
    Xml    => "Content-Type" => "application/xml; charset=utf-8",
    Binary => "Content-Type" => "application/octet-stream",
)

@inline function content_type_pair(::Type{T})::Pair{String,String} where {T<:AbstractFormat}
    return get(_CONTENT_PAIRS, T) do
        "Content-Type" => mime(T)
    end
end

# --- Body encoding (extensible via dispatch) ---

"""
    encode(Format, body) → String / Vector{UInt8}

Convert `body` to the wire representation for `Format`.
Extend for custom formats:
```julia
Mongoose.encode(::Type{MyFormat}, body) = serialize(body)
```
"""
encode(::Type{T}, body) where {T<:AbstractFormat} = error("encode not implemented for $T with body::$(typeof(body)). Implement `Mongoose.encode(::Type{$T}, body)`.")
encode(::Type{Plain}, body::String) = body
encode(::Type{Html}, body::String) = body
encode(::Type{Css}, body::String) = body
encode(::Type{Js}, body::String) = body
encode(::Type{Xml}, body::String) = body
encode(::Type{Binary}, body::Vector{UInt8}) = body

# Built-in JSON encoding via JSON3
encode(::Type{Json}, body::AbstractDict) = JSON3.write(body)
encode(::Type{Json}, body::AbstractVector) = JSON3.write(body)
encode(::Type{Json}, body::NamedTuple) = JSON3.write(body)
encode(::Type{Json}, body::String) = body  # passthrough for pre-serialized JSON

"""
    decode(Format, body::String) → Any

Parse a request body from its wire representation.
Extend for custom formats:
```julia
Mongoose.decode(::Type{MyFormat}, body::String) = deserialize(body)
```
"""
decode(::Type{T}, body::String) where {T<:AbstractFormat} = error("decode not implemented for $T. Implement `Mongoose.decode(::Type{$T}, body::String)`.")
decode(::Type{Json}, body::String) = JSON3.read(body)
decode(::Type{Json}, body::String, ::Type{T}) where {T} = JSON3.read(body, T)
