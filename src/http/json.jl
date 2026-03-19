"""
    JSON integration — convenience functions for JSON request/response handling.
    Uses the JSON.jl package for serialization.
"""

import JSON

"""
    json_response(data; status=200, headers=Dict{String,String}())

Create an HTTP response with JSON-serialized body and appropriate Content-Type header.

# Arguments
- `data`: Any Julia object serializable by `JSON.json()`.
- `status::Int`: HTTP status code (default: `200`).
- `headers::Dict{String,String}`: Additional headers (default: empty).

# Example
```julia
route!(server, :get, "/api/data", (req, params) -> begin
    json_response(Dict("message" => "Hello!", "count" => 42))
end)
```
"""
function json_response(data; status::Int=200, headers::Dict{String,String}=Dict{String,String}())
    headers["Content-Type"] = "application/json"
    body = JSON.json(data)
    return HttpResponse(status, headers, body)
end

"""
    json_body(request) → Any

Parse the request body as JSON and return the parsed Julia object (typically a Dict).
Throws on invalid JSON.

# Example
```julia
route!(server, :post, "/api/data", (req, params) -> begin
    data = json_body(req)
    json_response(Dict("received" => data))
end)
```
"""
function json_body(request::AbstractRequest)
    b = if request isa HttpRequest
        request.body
    elseif request isa ViewRequest
        body(request)
    else
        ""
    end
    return JSON.parse(b)
end

"""
    json_body(request, ::Type{T}) where T → T

Parse the request body as JSON and deserialize into a struct of type `T`.
The type `T` must have a constructor accepting keyword arguments matching the JSON keys.

# Example
```julia
struct CreateUser
    name::String
    email::String
end

route!(server, :post, "/users", (req, params) -> begin
    user = json_body(req, CreateUser)
    json_response(Dict("created" => user.name))
end)
```
"""
function json_body(request::AbstractRequest, ::Type{T}) where T
    dict = json_body(request)
    return _dict_to_struct(T, dict)
end

"""
    _dict_to_struct(::Type{T}, dict) → T

Internal helper to convert a parsed JSON dict to a struct of type T.
"""
@generated function _dict_to_struct(::Type{T}, dict::Dict{String,Any}) where T
    fnames = fieldnames(T)
    ftypes = fieldtypes(T)
    exprs = [:(
        let val = get(dict, $(string(fname)), nothing)
            $(
                if ftype === String
                    :(val === nothing ? "" : string(val))
                elseif ftype === Bool
                    :(val === nothing ? false : Bool(val))
                elseif ftype === Int || ftype === Int64
                    :(val === nothing ? 0 : Int(val))
                elseif ftype === Float64
                    :(val === nothing ? 0.0 : Float64(val))
                elseif ftype isa Union && Nothing <: ftype
                    :(val === nothing ? nothing : val)
                else
                    :(val === nothing ? error("Cannot create default value for field type $($ftype) — provide a value in JSON") : convert($ftype, val))
                end
            )
        end
    ) for (fname, ftype) in zip(fnames, ftypes)]

    return :(T($(exprs...)))
end
