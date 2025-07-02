module Mongoose

using Mongoose_jll

export mg_serve, mg_shutdown,
       mg_register,
       mg_query, mg_proto, mg_body, mg_message, mg_headers,
       mg_http_reply, mg_json_reply, mg_text_reply

# --- 1. Constantes y punteros ---
const MG_EV_HTTP_MSG = Cint(11) # For full requests
const MG_PTR_MGR = Ptr{Cvoid}
const MG_PTR_CONNECTION = Ptr{Cvoid}
const MG_PTR_EVENT_HANDLER_T = Ptr{Cvoid} # Pointer to the event handler function

# --- 2. Wrapper de Funciones C de Mongoose ---
function mg_mgr_init(mgr::MG_PTR_MGR)::Cvoid
    ccall((:mg_mgr_init, libmongoose), Cvoid, (MG_PTR_MGR,), mgr)
end

function mg_http_listen(mgr::MG_PTR_MGR, url::Cstring, handler::MG_PTR_EVENT_HANDLER_T, userdata::Ptr{Cvoid})::MG_PTR_CONNECTION
    ccall((:mg_http_listen, libmongoose), MG_PTR_CONNECTION, (MG_PTR_MGR, Cstring, MG_PTR_EVENT_HANDLER_T, Ptr{Cvoid}), mgr, Base.unsafe_convert(Cstring, url), handler, userdata)
end

function mg_mgr_poll(mgr::MG_PTR_MGR, timeout_ms::Int)::Cint
    ccall((:mg_mgr_poll, libmongoose), Cint, (MG_PTR_MGR, Cint), mgr, Cint(timeout_ms))
end

function mg_http_reply(conn::MG_PTR_CONNECTION, status::Int, headers::String, body::String)::Cvoid
    ccall((:mg_http_reply, libmongoose), Cvoid, (MG_PTR_CONNECTION, Cint, Cstring, Cstring), conn, Cint(status), Base.unsafe_convert(Cstring, headers), Base.unsafe_convert(Cstring, body))
end

function mg_json_reply(conn::MG_PTR_CONNECTION, status::Int, body::String)
    mg_http_reply(conn, status, "Content-Type: application/json\r\n", body)
end

function mg_text_reply(conn::MG_PTR_CONNECTION, status::Int, body::String)
    mg_http_reply(conn, status, "Content-Type: text/plain\r\n", body)
end

function mg_mgr_free(mgr::MG_PTR_MGR)::Cvoid
    ccall((:mg_mgr_free, libmongoose), Cvoid, (MG_PTR_MGR,), mgr)
end

# --- 3. Estructuras de Datos ---
struct MgStr
    ptr::Cstring # Pointer to the string data
    len::Csize_t # Length of the string
end

const MG_MAX_HTTP_HEADERS = 30 # Número máximo de cabeceras HTTP

struct MgHttpHeader
    name::MgStr
    val::MgStr
end

struct MgHttpMessage
    method::MgStr
    uri::MgStr
    query::MgStr
    proto::MgStr
    headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader} # Array of headers
    body::MgStr
    message::MgStr
end

mg_method(message::MgHttpMessage) = mg_str(message.method)
mg_uri(message::MgHttpMessage) = mg_str(message.uri)
mg_query(message::MgHttpMessage) = mg_str(message.query)
mg_proto(message::MgHttpMessage) = mg_str(message.proto)
mg_body(message::MgHttpMessage) = mg_str(message.body)
mg_message(message::MgHttpMessage) = mg_str(message.message)
function mg_headers(message::MgHttpMessage)
    headers = Dict{String, String}()
    for header in message.headers
        if header.name.ptr != C_NULL && header.name.len > 0
            name = mg_str(header.name)
            value = mg_str(header.val)
            headers[name] = value
        end
    end
    return headers
end

function mg_http_message(ev_data::Ptr{Cvoid})::MgHttpMessage
    if ev_data == C_NULL
        error("ev_data for HTTP message is NULL")
    end
    return Base.unsafe_load(Ptr{MgHttpMessage}(ev_data))
end

function mg_str(str::MgStr)
    if str.ptr == C_NULL || str.len == 0
        return ""
    end
    return Base.unsafe_string(pointer(str.ptr), str.len)
end

mutable struct MgRoute
    handlers::Dict{Symbol, Function}
end

mutable struct MgRouter
    routes::Dict{String, MgRoute}
    MgRouter() = new(Dict{String, MgRoute}())
end

const MG_ROUTER = MgRouter()

function mg_register(method::AbstractString, uri::AbstractString, handler::Function)
    method = uppercase(method)
    valid_methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    if !(method in valid_methods)
        error("Invalid HTTP method: $method. Valid methods are: $valid_methods")
    end
    method = Symbol(method)
    if !haskey(MG_ROUTER.routes, uri)
        MG_ROUTER.routes[uri] = MgRoute(Dict{Symbol, Function}())
    end
    MG_ROUTER.routes[uri].handlers[method] = handler
    return
end

# --- 5. El Callback Principal de Mongoose ---
function mg_event_handler(conn::MG_PTR_CONNECTION, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    # @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data"
    if ev == MG_EV_HTTP_MSG
        message = mg_http_message(ev_data)
        uri = mg_uri(message)
        method = mg_method(message) |> Symbol
        # @info "Handling request: $method $uri"
        route = get(MG_ROUTER.routes, uri, nothing)
        if isnothing(route)
            @warn "404 Not Found: $method $uri"
            return mg_http_reply(conn, 404, "Content-Type: text/plain\r\n", "404 Not Found")
        elseif !haskey(route.handlers, method)
            @warn "405 Method Not Allowed: $method $uri"
            return mg_text_reply(conn, 405, "405 Method Not Allowed")
        else
            try
                route.handlers[method](conn, message)
            catch e
                @error "Error handling request: $e" error = (e, catch_backtrace())
                return mg_text_reply(conn, 500, "500 Internal Server Error")
            end
        end
    end
end

mutable struct MgServer
    mgr::MG_PTR_MGR
    listener::MG_PTR_CONNECTION
    is_running::Bool
    task::Union{Task, Nothing}
end

const MG_SERVER = MgServer(C_NULL, C_NULL, false, nothing)

function mg_serve(host::AbstractString="127.0.0.1", port::Integer=8080)::Nothing
    if MG_SERVER.is_running
        @warn "Server already running."
        return
    end
    mgr_ptr = Libc.malloc(Csize_t(128)) # Damos un poco de espacio extra
    mg_mgr_init(mgr_ptr)
    MG_SERVER.mgr = mgr_ptr
    @info "Mongoose manager initialized."
    ptr_mg_event_handler = @cfunction(mg_event_handler, Cvoid, (MG_PTR_CONNECTION, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    url = "http://$host:$port" #"http://0.0.0.0:$port"
    listener = mg_http_listen(MG_SERVER.mgr, Cstring(pointer(url)), ptr_mg_event_handler, C_NULL)
    if listener == C_NULL
        Libc.free(mgr_ptr)
        # mg_mgr_free NO es necesario porque el manager no llegó a usarse.
        @error "Mongoose failed to listen on $url. errno: $(Libc.errno())"
        error("Failed to start server.")
    end
    MG_SERVER.listener = listener
    @info "Listening on $url"
    MG_SERVER.is_running = true
    MG_SERVER.task = @async begin
        try
            while MG_SERVER.is_running
                mg_mgr_poll(MG_SERVER.mgr, 1)
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

function mg_shutdown()::Nothing
    if MG_SERVER.is_running
        @info "Stopping server..."
        MG_SERVER.is_running = false
        if !isnothing(MG_SERVER.task)
            @info "Waiting for event loop to exit..."
            wait(MG_SERVER.task)
            MG_SERVER.task = nothing
        end
        if MG_SERVER.mgr != C_NULL
            @info "Freeing Mongoose manager and closing connections..."
            mg_mgr_free(MG_SERVER.mgr)
            Libc.free(MG_SERVER.mgr)
            MG_SERVER.mgr = C_NULL
        end
        @info "Server stopped successfully."
    else
        @warn "Server not running."
    end
    return
end

end
