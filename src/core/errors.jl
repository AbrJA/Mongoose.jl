abstract type MongooseError <: Exception end

struct RouteError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::RouteError) = print(io, "RouteError: ", e.msg)

struct ServerError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::ServerError) = print(io, "ServerError: ", e.msg)

struct BindError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::BindError) = print(io, "BindError: ", e.msg)
