# Using the structs from wrappers.jl
struct Request
   method::String
   uri::String
   query::String
   headers::Dict{String, String}
   body::String

   function Request(message::MgHttpMessage)
       return new(_method(message), _uri(message), _query(message), _headers(message), _body(message))
   end
end

struct IdRequest
    id::Int
    payload::Request
end

struct Response
    status::Int
    headers::Dict{String, String}
    body::String
end

struct IdResponse
    id::Int
    payload::Response
end

_method(message::MgHttpMessage) = to_string(message.method)
_uri(message::MgHttpMessage) = to_string(message.uri)
_query(message::MgHttpMessage) = to_string(message.query)
_proto(message::MgHttpMessage) = to_string(message.proto)
_body(message::MgHttpMessage) = to_string(message.body)
_message(message::MgHttpMessage) = to_string(message.message)

function _headers(message::MgHttpMessage)::Dict{String, String}
    headers = Dict{String, String}()
    sizehint!(headers, length(message.headers))
    for header in message.headers
        if header.name.ptr != C_NULL && header.name.len > 0 && header.val.ptr != C_NULL && header.val.len > 0
            name = to_string(header.name)
            value = to_string(header.val)
            headers[name] = value
        end
    end
    return headers
end

function to_string(headers::Dict{String, String})
    io = IOBuffer()
    for (k, v) in headers
           print(io, k, ": ", v, "\r\n")
    end
    return String(take!(io))
end

# Router
struct Route
    handlers::Dict{String, Function}
    Route() = new(Dict{String, Function}())
end

mutable struct Router
    static::Dict{String, Route}
    dynamic::Dict{Regex, Route}
    Router() = new(Dict{String, Route}(), Dict{Regex, Route}())
end

# Server
mutable struct Manager
    ptr::Ptr{Cvoid}
    function Manager()
        ptr = Libc.malloc(Csize_t(128))
        ptr == C_NULL && error("Failed to allocate manager memory")
        mg_mgr_init!(ptr)
        mgr = new(ptr)
        finalizer(mgr_cleanup!, mgr)
        return mgr
    end
end

function mgr_cleanup!(mgr::Manager)
    if mgr.ptr != C_NULL
        mg_mgr_free!(mgr.ptr)
        Libc.free(mgr.ptr)
        mgr.ptr = C_NULL
    end
end

mutable struct Server
    manager::Manager
    listener::Ptr{Cvoid}
    handler::Ptr{Cvoid}
    task::Union{Task, Nothing}
    router::Router
    timeout::Int
    running::Bool

    function Server(; timeout::Integer = 0, log_level::Integer = 0)
        mg_log_set_level(log_level)
        return new(Manager(), C_NULL, C_NULL, nothing, Router(), timeout, false)
    end
end
