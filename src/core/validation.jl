"""
    Request validation — automatic parsing and validation of request bodies.

    Provides `@validate` macro and `validate` function for type-safe request parsing.
    Works with any struct that has a constructor accepting keyword arguments or a Dict.

    # Usage Patterns

    ## 1. Manual validation in handler:
    ```julia
    post!(app, "/users") do req
        data = validate(req, CreateUser)
        # data is a validated CreateUser instance
        json((id=1, name=data.name))
    end
    ```

    ## 2. Validation with custom error responses:
    ```julia
    post!(app, "/users") do req
        data = validate(req, CreateUser) do err
            json((error=err,); status=422)
        end
        json((id=1, name=data.name))
    end
    ```
"""

"""
    ValidationError — Thrown when request body fails validation.
"""
struct ValidationError <: Exception
    message::String
    field::Union{Nothing,String}
end

ValidationError(msg::String) = ValidationError(msg, nothing)

function Base.showerror(io::IO, e::ValidationError)
    if e.field !== nothing
        print(io, "ValidationError: field '$(e.field)' — $(e.message)")
    else
        print(io, "ValidationError: $(e.message)")
    end
end

"""
    validate(req, ::Type{T}) → T
    validate(error_handler, req, ::Type{T}) → Union{T, Response}

Parse and validate the JSON request body into type T.
T must be a struct with a keyword constructor or accept a Dict.

Returns the parsed struct, or throws `ValidationError` if parsing fails.
When called with an error handler function, returns the handler's response on failure.

# Example
```julia
struct CreateUser
    name::String
    email::String
    age::Int
end

post!(app, "/users") do req
    user = validate(req, CreateUser)
    json((id=1, name=user.name))
end
```
"""
function validate(req::Request, ::Type{T})::T where {T}
    body_str = req.body
    isempty(body_str) && throw(ValidationError("Request body is empty"))

    data = try
        JSON.parse(body_str)
    catch e
        throw(ValidationError("Invalid JSON: $(sprint(showerror, e))"))
    end

    data isa Dict || throw(ValidationError("Expected JSON object, got $(typeof(data))"))

    return _construct_from_dict(T, data)
end

function validate(on_error::Function, req::Request, ::Type{T}) where {T}
    try
        return validate(req, T)
    catch e
        e isa ValidationError || rethrow(e)
        return on_error(e.message)
    end
end

"""
    _construct_from_dict(T, data::Dict) → T

Attempt to construct type T from a parsed JSON Dict.
Supports types with keyword constructors or positional constructors matching fieldnames.
"""
function _construct_from_dict(::Type{T}, data::Dict)::T where {T}
    fields = fieldnames(T)
    types = fieldtypes(T)
    args = Any[]

    for (i, fname) in enumerate(fields)
        key = String(fname)
        ftype = types[i]

        if !haskey(data, key)
            # Optional fields (Union{Nothing,X}) get nothing when missing
            if _is_optional_type(ftype)
                push!(args, nothing)
                continue
            end
            throw(ValidationError("Missing required field: '$key'", key))
        end

        raw = data[key]
        # Handle null for optional fields
        actual_type = _is_optional_type(ftype) ? _unwrap_optional(ftype) : ftype
        if raw === nothing && _is_optional_type(ftype)
            push!(args, nothing)
            continue
        end

        converted = try
            _coerce_field(actual_type, raw)
        catch e
            e isa ValidationError && rethrow(e)
            throw(ValidationError("Invalid value for '$key': expected $ftype, got $(typeof(raw))", key))
        end
        push!(args, converted)
    end

    try
        return T(args...)
    catch e
        throw(ValidationError("Failed to construct $(nameof(T)): $(sprint(showerror, e))"))
    end
end

# Type coercion for common JSON → Julia conversions
@inline _coerce_field(::Type{String}, v::AbstractString) = String(v)
@inline _coerce_field(::Type{String}, v) = throw(ValidationError("expected String"))
@inline _coerce_field(::Type{Int}, v::Integer) = Int(v)
@inline _coerce_field(::Type{Int}, v::AbstractFloat) = isinteger(v) ? Int(v) : throw(ValidationError("expected Int"))
@inline _coerce_field(::Type{Float64}, v::Number) = Float64(v)
@inline _coerce_field(::Type{Bool}, v::Bool) = v
@inline _coerce_field(::Type{T}, v::AbstractVector) where {T<:AbstractVector} = T(v)
@inline _coerce_field(::Type{Vector{String}}, v::AbstractVector) = String[String(x) for x in v]
@inline _coerce_field(::Type{Vector{Int}}, v::AbstractVector) = Int[Int(x) for x in v]
@inline _coerce_field(::Type{T}, v) where {T} = v isa T ? v : convert(T, v)

# Optional field support — handled in _construct_from_dict for Union{Nothing,T} fields
function _is_optional_type(T::Type)::Bool
    T isa Union && Nothing <: T
end

function _unwrap_optional(T::Type)::Type
    # For Union{Nothing, X}, return X
    T === Nothing && return Nothing
    if T isa Union
        T.a === Nothing && return T.b
        T.b === Nothing && return T.a
    end
    return T
end
