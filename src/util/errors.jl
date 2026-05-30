"""
    Custom exception types for Mongoose.jl.
    Structured hierarchy with error codes for machine-readable error handling.
"""
abstract type MongooseError <: Exception end

"""
    RouteError — Route registration or matching failure.
"""
struct RouteError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::RouteError) = print(io, "RouteError: ", e.msg)

"""
    ServerError — Server operation failure (initialization, memory, config).
"""
struct ServerError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::ServerError) = print(io, "ServerError: ", e.msg)

"""
    BindError — Failed to bind to address/port.
"""
struct BindError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::BindError) = print(io, "BindError: ", e.msg)
