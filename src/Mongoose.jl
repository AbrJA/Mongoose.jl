module Mongoose

using Mongoose_jll

export MgConnection, MgHttpMessage,
       mg_serve!, mg_shutdown!,
       mg_register!,
       mg_method, mg_uri, mg_query, mg_proto, mg_body, mg_message, mg_headers,
       mg_http_reply, mg_json_reply, mg_text_reply

# --- 1. Constants and Types ---
"""
    MgConnection
A type alias for a pointer to a Mongoose connection. This is used to represent a connection to a client in the Mongoose server.
"""
const MgConnection = Ptr{Cvoid} # Pointer to a generic C void type

# --- 2. Function wrappers for Mongoose C API ---
function mg_mgr_init!(mgr::Ptr{Cvoid})::Cvoid
    ccall((:mg_mgr_init, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

function mg_mgr_free!(mgr::Ptr{Cvoid})::Cvoid
    ccall((:mg_mgr_free, libmongoose), Cvoid, (Ptr{Cvoid},), mgr)
end

function mg_http_listen(mgr::Ptr{Cvoid}, url::String, handler::Ptr{Cvoid}, userdata::Ptr{Cvoid})::Ptr{Cvoid}
    ccall((:mg_http_listen, libmongoose), Ptr{Cvoid}, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}, Ptr{Cvoid}), mgr, Base.unsafe_convert(Cstring, url), handler, userdata)
end

function mg_mgr_poll(mgr::Ptr{Cvoid}, timeout_ms::Int)::Cint
    ccall((:mg_mgr_poll, libmongoose), Cint, (Ptr{Cvoid}, Cint), mgr, Cint(timeout_ms))
end

"""
    mg_http_reply(conn::MgConnection, status::Int, headers::String, body::String)::Cvoid

Sends an HTTP reply to a connected client. It constructs and sends an HTTP response including the status code, headers, and body.

# Arguments
- `conn::MgConnection`: A pointer to the Mongoose connection to which the reply should be sent.
- `status::Int`: The HTTP status code (e.g., 200 for OK, 404 for Not Found).
- `headers::String`: A string containing HTTP headers, separated by `\\r\\n`. For example: `"Content-Type: text/plain\\r\\nCustom-Header: value\\r\\n"`.
- `body::String`: The body of the HTTP response.
"""
function mg_http_reply(conn::MgConnection, status::Int, headers::String, body::String)::Cvoid
    ccall((:mg_http_reply, libmongoose), Cvoid, (Ptr{Cvoid}, Cint, Cstring, Cstring), conn, Cint(status), Base.unsafe_convert(Cstring, headers), Base.unsafe_convert(Cstring, body))
end

"""
    mg_json_reply(conn::MgConnection, status::Int, body::String)

This is a convenience function that calls `mg_http_reply` with the `Content-Type` header set to `application/json`.
"""
function mg_json_reply(conn::MgConnection, status::Int, body::String)
    mg_http_reply(conn, status, "Content-Type: application/json\r\n", body)
end

"""
    mg_text_reply(conn::MgConnection, status::Int, body::String)

This is a convenience function that calls `mg_http_reply` with the `Content-Type` header set to `text/plain`.
"""
function mg_text_reply(conn::MgConnection, status::Int, body::String)
    mg_http_reply(conn, status, "Content-Type: text/plain\r\n", body)
end

# --- 3. Data Structures ---
"""
    struct MgStr
        ptr::Cstring
        len::Csize_t
    end

A Julia representation of Mongoose's `struct mg_str` which is a view into a string buffer. It's used to represent strings returned by Mongoose.

# Fields
- `ptr::Cstring`: A pointer to the beginning of the string data in memory.
- `len::Csize_t`: The length of the string in bytes.
"""
struct MgStr
    ptr::Cstring # Pointer to the string data
    len::Csize_t # Length of the string
end

const MG_EV_HTTP_MSG = Cint(11) # For full requests
const MG_MAX_HTTP_HEADERS = 30 # Maximum number of HTTP headers allowed

"""
    struct MgHttpHeader
        name::MgStr
        val::MgStr
    end

A Julia representation of Mongoose's `struct mg_http_header`, representing a single HTTP header.

# Fields
- `name::MgStr`: An `MgStr` structure representing the header field name (e.g., "Content-Type").
- `val::MgStr`: An `MgStr` structure representing the header field value (e.g., "application/json").
"""
struct MgHttpHeader
    name::MgStr
    val::MgStr
end

"""
    struct MgHttpMessage
        method::MgStr
        uri::MgStr
        query::MgStr
        proto::MgStr
        headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader}
        body::MgStr
        message::MgStr
    end

A Julia representation of Mongoose's `struct mg_http_message`, containing parsed information about an HTTP request or response.

# Fields
- `method::MgStr`: The HTTP method (e.g., "GET", "POST").
- `uri::MgStr`: The request URI (e.g., "/api/data").
- `query::MgStr`: The query string part of the URI (e.g., "id=123").
- `proto::MgStr`: The protocol string (e.g., "HTTP/1.1").
- `headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader}`: A tuple of `MgHttpHeader` structs representing the HTTP headers.
- `body::MgStr`: The body of the HTTP message.
- `message::MgStr`: The entire raw HTTP message.
"""
struct MgHttpMessage
    method::MgStr
    uri::MgStr
    query::MgStr
    proto::MgStr
    headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader} # Array of headers
    body::MgStr
    message::MgStr
end

"""
    mg_method(message::MgHttpMessage) -> String

Extracts the HTTP method from an `MgHttpMessage` as a Julia `String`.

# Arguments
- `message::MgHttpMessage`: The HTTP message object.

# Returns
`String`: The HTTP method (e.g., "GET", "POST").
"""
mg_method(message::MgHttpMessage) = mg_str(message.method)

"""
    mg_uri(message::MgHttpMessage) -> String

Extracts the URI from an `MgHttpMessage` as a Julia `String`.

# Arguments
- `message::MgHttpMessage`: The HTTP message object.

# Returns
`String`: The request URI (e.g., "/api/users").
"""
mg_uri(message::MgHttpMessage) = mg_str(message.uri)

"""
    mg_query(message::MgHttpMessage) -> String

Extracts the query string from an `MgHttpMessage` as a Julia `String`.

# Arguments
- `message::MgHttpMessage`: The HTTP message object.

# Returns
`String`: The query string (e.g., "param=value&id=1").
"""
mg_query(message::MgHttpMessage) = mg_str(message.query)

"""
    mg_proto(message::MgHttpMessage) -> String

Extracts the protocol string from an `MgHttpMessage` as a Julia `String`.

# Arguments
- `message::MgHttpMessage`: The HTTP message object.

# Returns
`String`: The protocol string (e.g., "HTTP/1.1").
"""
mg_proto(message::MgHttpMessage) = mg_str(message.proto)

"""
    mg_body(message::MgHttpMessage) -> String

Extracts the body of the HTTP message from an `MgHttpMessage` as a Julia `String`.

# Arguments
- `message::MgHttpMessage`: The HTTP message object.

# Returns
`String`: The body content of the HTTP message.
"""
mg_body(message::MgHttpMessage) = mg_str(message.body)

"""
    mg_message(message::MgHttpMessage) -> String

Extracts the entire raw HTTP message from an `MgHttpMessage` as a Julia `String`.

# Arguments
- `message::MgHttpMessage`: The HTTP message object.

# Returns
`String`: The complete raw HTTP message string.
"""
mg_message(message::MgHttpMessage) = mg_str(message.message)

"""
    mg_headers(message::MgHttpMessage) -> NamedTuple

Extracts all HTTP headers from an `MgHttpMessage` into a Julia `Named Tuple`.

# Arguments
- `message::MgHttpMessage`: The HTTP message object.

# Returns
`NamedTuple`: A dictionary where keys are header names and values are header values.
"""
function mg_headers(message::MgHttpMessage)::NamedTuple
    headers = Pair{String, String}[]
    for header in message.headers
        if header.name.ptr != C_NULL && header.name.len > 0
            name = mg_str(header.name)
            value = mg_str(header.val)
            push!(header_pairs, name => value)
        end
    end
    return (; headers...)
end

function mg_http_message(ev_data::Ptr{Cvoid})::MgHttpMessage
    if ev_data == C_NULL
        error("ev_data for HTTP message is NULL")
    end
    return Base.unsafe_load(Ptr{MgHttpMessage}(ev_data))
end

function mg_str(str::MgStr)::String
    if str.ptr == C_NULL || str.len == 0
        return ""
    end
    return Base.unsafe_string(pointer(str.ptr), str.len)
end

struct MgRoute
    handlers::Dict{Symbol, Function}
    MgRoute() = new(Dict{Symbol, Function}())
end

mutable struct MgRouter
    static::Dict{String, MgRoute}
    dynamic::Dict{Regex, MgRoute}
    MgRouter() = new(Dict{String, MgRoute}(), Dict{Regex, MgRoute}())
end

const MG_ROUTER = Ref{MgRouter}()

function mg_global_router()::MgRouter
    if !isassigned(MG_ROUTER)
        MG_ROUTER[] = MgRouter()
    end
    return MG_ROUTER[]
end

# --- 4. Request Handler Registration ---
"""
    mg_register!(method::Symbol, uri::AbstractString, handler::Function)

Registers an HTTP request handler for a specific method and URI.

# Arguments
- `method::Symbol`: The HTTP method (e.g., :GET, :POST, :PUT, :PATCH, :DELETE).
- `uri::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
- `handler::Function`: The Julia function to be called when a matching request arrives.

This function should accept two arguments: `(conn::MgConnection, message::MgHttpMessage)`.
"""
function mg_register!(method::Symbol, uri::AbstractString, handler::Function; router::MgRouter = mg_global_router())::Nothing
    valid_methods = [:GET, :POST, :PUT, :PATCH, :DELETE]
    if !(method in valid_methods)
        error("Invalid HTTP method: $method. Valid methods are: $valid_methods")
    end
    if occursin(':', uri)
        regex = Regex("^" * replace(uri, r":([a-zA-Z0-9_]+)" => s"(?P<\1>[^/]+)") * "\$")
        if !haskey(router.dynamic, regex)
            router.dynamic[regex] = MgRoute()
        end
        router.dynamic[regex].handlers[method] = handler
    else
        if !haskey(router.static, uri)
            router.static[uri] = MgRoute()
        end
        router.static[uri].handlers[method] = handler
    end
    return
end

function mg_route_handler(conn::Ptr{Cvoid}, message::MgHttpMessage, method::Symbol, route::MgRoute; kwargs...)
    if haskey(route.handlers, method)
            try
                return route.handlers[method](conn, message; kwargs...)
            catch e # CHECK THIS TO ALWAYS RESPOND
                @error "Error handling request: $e" error = (e, catch_backtrace())
                return mg_text_reply(conn, 500, "500 Internal Server Error")
            end
    else
        @warn "405 Method Not Allowed: $method $uri"
        return mg_text_reply(conn, 405, "405 Method Not Allowed")
    end
end

# --- 5. Event handling ---
function mg_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid}; router::MgRouter = mg_global_router())
    # @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data, FnData: $fn_data"
    if ev !== MG_EV_HTTP_MSG
        return
    end
    message = mg_http_message(ev_data)
    uri = mg_uri(message)
    method = Symbol(mg_method(message))
    route = get(router.static, uri, nothing)
    if !isnothing(route)
        return mg_route_handler(conn, message, method, route)
    end
    for (regex, route) in router.dynamic
        matched = match(regex, uri)
        if !isnothing(matched)
            return mg_route_handler(conn, message, method, route; params = matched)
        end
    end
    @warn "404 Not Found: $uri"
    return mg_text_reply(conn, 404, "404 Not Found")
end

mutable struct MgServer
    mgr::Ptr{Cvoid}
    listener::Ptr{Cvoid}
    running::Bool
    task::Union{Task, Nothing}
end

const MG_SERVER = Ref{MgServer}()

function mg_global_server()::MgServer
    if !isassigned(MG_SERVER)
        MG_SERVER[] = MgServer(C_NULL, C_NULL, false, nothing)
    end
    return MG_SERVER[]
end

# --- 6. Server Management ---
"""
    mg_serve!(host::AbstractString="127.0.0.1", port::Integer=8080)::Nothing

Starts the Mongoose HTTP server. Initialize the Mongoose manager, binds an HTTP listener, and starts a background Task to poll the Mongoose event loop.

Arguments
- `host::AbstractString="127.0.0.1"`: The IP address or hostname to listen on. Defaults to "127.0.0.1" (localhost).
- `port::Integer=8080`: The port number to listen on. Defaults to 8080.
"""
function mg_serve!(host::AbstractString="127.0.0.1", port::Integer=8080; router::MgRouter = mg_global_router(), server::MgServer = mg_global_server())::Nothing
    if server.running
        @warn "Server already running."
        return
    end
    ptr_mgr = Libc.malloc(Csize_t(128)) # Allocate memory for the Mongoose manager
    mg_mgr_init!(ptr_mgr)
    server.mgr = ptr_mgr
    @info "Mongoose manager initialized."
    ptr_mg_event_handler = @cfunction(mg_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    url = "http://$host:$port"
    listener = mg_http_listen(server.mgr, url, ptr_mg_event_handler, C_NULL)
    if listener == C_NULL
        Libc.free(ptr_mgr)
        # mg_mgr_free isn't needed here since we free the manager later
        @error "Mongoose failed to listen on $url. errno: $(Libc.errno())"
        error("Failed to start server.")
    end
    server.listener = listener
    @info "Listening on $url"
    server.running = true
    server.task = @async begin
        try
            while server.running
                mg_mgr_poll(server.mgr, 1)
                yield()
            end
        catch e
            if !isa(e, InterruptException)
                @error "Server loop error: $e" error = (e, catch_backtrace())
            end
        end
        @info "Event loop task finished."
    end
    @info "Server started in background task."
    return
end

"""
    mg_shutdown!()::Nothing

Stops the running Mongoose HTTP server. Sets a flag to stop the background event loop task, and then frees the Mongoose associated resources.
"""
function mg_shutdown!(; server::MgServer = mg_global_server())::Nothing
    if server.running
        @info "Stopping server..."
        server.running = false
        if !isnothing(server.task)
            @info "Waiting for event loop to exit..."
            wait(server.task)
            server.task = nothing
        end
        if server.mgr != C_NULL
            @info "Freeing Mongoose manager and closing connections..."
            mg_mgr_free!(server.mgr)
            Libc.free(server.mgr)
            server.mgr = C_NULL
        end
        @info "Server stopped successfully."
    else
        @warn "Server not running."
    end
    return
end

end
