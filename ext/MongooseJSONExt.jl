"""
    MongooseJSONExt — JSON integration loaded when `using JSON` alongside Mongoose.
"""
module MongooseJSONExt

import JSON
import Mongoose: AbstractResponse, Response, AbstractRequest, Json, Headers,
                 _body, _format_headers, content_type, json

"""
    json(data; status=200, headers=Headers())

Create a JSON response with serialized body and `application/json` Content-Type.

# Example
```julia
route!(router, :get, "/api/data", req -> json(Dict("message" => "Hello!")))
json(Dict("created" => true); status=201)
```
"""
function json(data; status=200, headers=Headers())
    ct = "Content-Type: application/json\r\n"
    extra = _format_headers(headers)
    return Response(status, ct * extra, JSON.json(data))
end

"""
    json(request) → Any

Parse the request body as JSON into a Dict.
"""
function json(request::AbstractRequest)
    return JSON.parse(_body(request))
end

"""
    json(request, ::Type{T}) where T → T

Parse the request body as JSON and deserialize into struct `T`.
"""
function json(request::AbstractRequest, ::Type{T}) where T
    JSON.parse(_body(request), T)
end

end # module
