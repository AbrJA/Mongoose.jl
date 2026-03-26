"""
    MongooseJSONExt — JSON integration loaded when `using JSON` alongside Mongoose.
"""
module MongooseJSONExt

import JSON
import Mongoose: Json, render_body, content_type

content_type(::Type{Json}) = "Content-Type: application/json; charset=utf-8\r\n"

"""
    render_body(::Type{Json}, body) → String

Renders a Julia object to a JSON string using the JSON.jl package.
"""
render_body(::Type{Json}, body) = JSON.json(body)

end # module
