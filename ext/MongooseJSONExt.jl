"""
    MongooseJSONExt — JSON integration loaded when `using JSON` alongside Mongoose.
"""
module MongooseJSONExt

import JSON
import Mongoose: AbstractResponse, Response, AbstractRequest, Json, body, _format_headers

"""
    Response(Json, Dict("message" => "Hello!"); status=200, headers=Dict{String,String}())

Create an HTTP response with JSON-serialized body and appropriate Content-Type header.
This returns a regular Response struct with JSON content.

# Example
```julia
route!(server, :get, "/api/data", req -> Response(Json, Dict("message" => "Hello!")))
```
"""
function Mongoose.Response(::Type{Json}, data; status=200, headers=Dict{String,String}())
    return json(data; status=status, headers=headers)
end

"""
    json(data; status=200, headers=Dict{String,String}())

Create a JSON response.
"""
function json(data; status=200, headers=Dict{String,String}())
    h = merge(Dict("Content-Type" => "application/json"), headers)
    return Response(status, _format_headers(h), JSON.json(data))
end

"""
    json(request) → Any

Parse the request body as JSON.
"""
function json(request::AbstractRequest)
    return JSON.parse(body(request))
end

"""
    json(request, ::Type{T}) where T → T

Parse the request body as JSON and deserialize into struct `T`.
"""
function json(request::AbstractRequest, ::Type{T}) where T
    JSON.parse(body(request), T)
end

end # module
