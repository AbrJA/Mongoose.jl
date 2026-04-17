"""
    Custom exception types for Mongoose.jl.
"""
abstract type MongooseError <: Exception end

"""
    RouteError — Thrown when route registration fails (e.g., parameter conflicts, invalid methods).
"""
struct RouteError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::RouteError) = print(io, "RouteError: ", e.msg)

"""
    ServerError — Thrown when server operations fail (e.g., memory allocation, initialization).
"""
struct ServerError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::ServerError) = print(io, "ServerError: ", e.msg)

"""
    BindError — Thrown when the server fails to bind to the specified address/port.
"""
struct BindError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::BindError) = print(io, "BindError: ", e.msg)
