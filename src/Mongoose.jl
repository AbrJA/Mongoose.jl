module Mongoose

using Mongoose_jll

export mg_serve, mg_shutdown, mg_register!

# --- 1. Constantes y punteros ---
const MG_EV_HTTP_MSG = Cint(11) # This is the main one for full requests
const PTR_MG_MGR = Ptr{Cvoid}
const PTR_MG_CONNECTION = Ptr{Cvoid}
const PTR_MG_EVENT_HANDLER_T = Ptr{Cvoid} # Tipo de la función de callback de eventos de Mongoose

# --- 2. Wrapper de Funciones C de Mongoose ---
function mg_mgr_init(mgr::PTR_MG_MGR)::Cvoid
    ccall((:mg_mgr_init, libmongoose), Cvoid, (PTR_MG_MGR,), mgr)
end

# Función para escuchar conexiones HTTP
function mg_http_listen(mgr::PTR_MG_MGR, url::Cstring, handler::PTR_MG_EVENT_HANDLER_T, userdata::Ptr{Cvoid})::PTR_MG_CONNECTION
    ccall((:mg_http_listen, libmongoose), PTR_MG_CONNECTION, (PTR_MG_MGR, Cstring, PTR_MG_EVENT_HANDLER_T, Ptr{Cvoid}), mgr, url, handler, userdata)
end

# Función para procesar eventos
function mg_mgr_poll(mgr::PTR_MG_MGR, timeout_ms::Cint)::Cint
    ccall((:mg_mgr_poll, libmongoose), Cint, (PTR_MG_MGR, Cint), mgr, timeout_ms)
end

# Función para responder a una petición HTTP
function mg_http_reply(conn::PTR_MG_CONNECTION, status::Cint, headers::Cstring, body::Cstring)::Cvoid
    ccall((:mg_http_reply, libmongoose), Cvoid, (PTR_MG_CONNECTION, Cint, Cstring, Cstring), conn, status, headers, body)
end

# Función para liberar el gestor de Mongoose
function mg_mgr_free(mgr::PTR_MG_MGR)::Cvoid
    ccall((:mg_mgr_free, libmongoose), Cvoid, (PTR_MG_MGR,), mgr)
end


# --- 3. Estructuras de Datos ---
struct MgStr
    ptr::Cstring # Puntero al inicio de la cadena
    len::Csize_t # Longitud de la cadena
end

const MG_MAX_HTTP_HEADERS = 30 # Número máximo de cabeceras HTTP

struct MgHttpHeader
    name::MgStr
    val::MgStr
end

# Función para obtener la URI de una petición HTTP
struct MgHttpMessage
    method::MgStr
    uri::MgStr
    query::MgStr
    proto::MgStr
    headers::NTuple{MG_MAX_HTTP_HEADERS, MgHttpHeader} # Array of headers
    body::MgStr
    head::MgStr
    message::MgStr
end

# Ahora podemos acceder a la URI de MgHttpMessage
function mg_http_message(ev_data::Ptr{Cvoid})::MgHttpMessage
    if ev_data == C_NULL
        error("ev_data for HTTP message is NULL")
    end
    return Base.unsafe_load(Ptr{MgHttpMessage}(ev_data))
end

function mg_str(ptr::Cstring, len::Csize_t)::String
    return Base.unsafe_string(pointer(ptr), len)
end

mutable struct Route
    handler::Dict{Symbol, Function}
end

mutable struct Router
    routes::Dict{String, Route}
    Router() = new(Dict{String, Route}())
end

# function mg_register!(method::Symbol, path::String, handler::Function)::Nothing
#     ROUTER.routes[(method, path)] = handler
#     return
# end

to_method(m::Symbol) = m
to_method(m::AbstractString) = Symbol(lowercase(m))

function mg_register!(router::Router, method::Union{Symbol,String}, path::String, handler::Function)
    m = to_method(method)
    if !haskey(router.routes, path)
        router.routes[path] = Route(Dict{Symbol, Function}())
    end
    router.routes[path].handlers[m] = handler
end

function mg_dispatch!(router::Router, method::Union{Symbol,String}, path::String, args...)
    m = to_method(method)
    entry = get(router.routes, path, nothing)

    if entry === nothing
        error("404 Not Found: $method $path")
    elseif !haskey(entry.handler, m)
        allowed = join(keys(entry.handlers), ", ")
        error("405 Method Not Allowed: $method $path. Allowed: $allowed")
    else
        return entry.handler[m](args...)
    end
end

# --- 5. El Callback Principal de Mongoose ---
# PTR_MG_EVENT_HANDLER_T espera (struct mg_connection *c, int ev, void *ev_data, void *fn_data) fn_data es opcional, lo usamos para pasar cualquier cosa a nuestro handler.
function mg_event_handler(conn::PTR_MG_CONNECTION, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    # @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data"

    if ev == MG_EV_HTTP_MSG
        http_msg = mg_http_message(ev_data)
        uri = mg_str(http_msg.uri.ptr, http_msg.uri.len)
        method = mg_str(http_msg.method.ptr, http_msg.method.len)

        handler = get(ROUTER.routes, (Symbol(method), uri), nothing)
        if isnothing(handler)
            @warn "404 Not Found: $method $uri"
            return mg_not_found_handler(conn)
        end
        try
            handler(conn)
        catch e
            @error "Error handling request: $e"
            Base.showerror(stderr, e, catch_backtrace())
            mg_internal_server_error_handler(conn)
        end
    end
    return
end

mutable struct ServerState
    mgr::PTR_MG_MGR
    listener::PTR_MG_CONNECTION
    is_running::Bool
    task::Union{Task, Nothing}
end

const SERVER_STATE = ServerState(C_NULL, C_NULL, false, nothing)

function mg_serve(port::Int=8080)::Nothing
    if SERVER_STATE.is_running
        @warn "Server already running."
        return
    end

    mgr_ptr = Libc.malloc(Csize_t(128)) # Damos un poco de espacio extra

    mg_mgr_init(mgr_ptr)
    SERVER_STATE.mgr = mgr_ptr
    @info "Mongoose manager initialized."

    ptr_mg_event_handler = @cfunction(mg_event_handler, Cvoid, (PTR_MG_CONNECTION, Cint, Ptr{Cvoid}, Ptr{Cvoid}))

    listen_url = "http://0.0.0.0:$port"
    listener_conn = mg_http_listen(SERVER_STATE.mgr, Cstring(pointer(listen_url)), ptr_mg_event_handler, C_NULL)

    if listener_conn == C_NULL
        Libc.free(mgr_ptr)
        # mg_mgr_free NO es necesario porque el manager no llegó a usarse.
        println(stderr, "Mongoose failed to listen on $listen_url. errno: $(Libc.errno())")
        error("Failed to start server.")
    end

    SERVER_STATE.listener = listener_conn
    @info "Listening on $listen_url"

    SERVER_STATE.is_running = true

    # Ejecutar el bucle de eventos en una tarea asíncrona
    SERVER_STATE.task = @async begin
        try
            while SERVER_STATE.is_running
                mg_mgr_poll(SERVER_STATE.mgr, Cint(1))
                yield()
            end
        catch e
            if !isa(e, InterruptException)
                println(stderr, "Server loop error: $e")
                Base.showerror(stderr, e, catch_backtrace())
            end
        end
        @info "Event loop task finished."
    end
    @info "Server started in background task."
    return
end

function mg_shutdown()::Nothing
    if SERVER_STATE.is_running
        @info "Stopping server..."
        SERVER_STATE.is_running = false

        if SERVER_STATE.task !== nothing
            @info "Waiting for event loop to exit..."
            wait(SERVER_STATE.task)
            SERVER_STATE.task = nothing
        end

        if SERVER_STATE.mgr != C_NULL
            @info "Freeing Mongoose manager and closing connections..."
            mg_mgr_free(SERVER_STATE.mgr)
            Libc.free(SERVER_STATE.mgr)
            SERVER_STATE.mgr = C_NULL
        end
        @info "Server stopped successfully."
    else
        @warn "Server not running."
    end
    return
end

## --- 6. Funciones de Utilidad ---
const MG_JSON_HEADER = "Content-Type: application/json\r\n"
const MG_TEXT_HEADER = "Content-Type: text/plain\r\n"

struct MgReply
    status::Int
    headers::String
    body::String
end

function mg_reply(status::Int, headers::String, body::String)
    return MgReply(status, headers, body)
end

function mg_json_reply(status::Int, body::String)
    return MgReply(status, MG_JSON_HEADER, body)
end

function mg_text_reply(status::Int, body::String)
    return MgReply(status, MG_TEXT_HEADER, body)
end

function mg_not_found_handler(conn::PTR_MG_CONNECTION)
    mg_http_reply(
        conn,
        Cint(404),
        Base.unsafe_convert(Cstring, MG_TEXT_HEADER),
        Base.unsafe_convert(Cstring, "404 Not Found")
    )
end

function mg_internal_server_error_handler(conn::PTR_MG_CONNECTION)
    mg_http_reply(
        conn,
        Cint(500),
        Base.unsafe_convert(Cstring, MG_TEXT_HEADER),
        Base.unsafe_convert(Cstring, "500 Internal Server Error")
    )
end

end
