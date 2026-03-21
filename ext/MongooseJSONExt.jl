"""
    MongooseJSONExt — JSON integration loaded when `using JSON` alongside Mongoose.
"""
module MongooseJSONExt

import JSON
import Mongoose: json_response, json_body, Response, AbstractRequest, body, _format_headers

"""
    json_response(data; status=200, headers=Dict{String,String}())

Create an HTTP response with JSON-serialized body and appropriate Content-Type header.

# Example
```julia
route!(server, :get, "/api/data", req -> json_response(Dict("message" => "Hello!")))
```
"""
function json_response(data; status::Int=200, headers::Dict{String,String}=Dict{String,String}())
    headers["Content-Type"] = "application/json"
    body = JSON.json(data)
    return Response(status, _format_headers(headers), body)
end

"""
    json_body(request) → Any

Parse the request body as JSON.
"""
function json_body(request::AbstractRequest)
    return JSON.parse(body(request))
end

"""
    json_body(request, ::Type{T}) where T → T

Parse the request body as JSON and deserialize into struct `T`.
"""
function json_body(request::AbstractRequest, ::Type{T}) where T
    dict = json_body(request)
    return _dict_to_struct(T, dict)
end

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

end # module
