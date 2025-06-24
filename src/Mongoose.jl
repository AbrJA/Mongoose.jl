module Mongoose

using Mongoose_jll

# --- 2. Constantes y Tipos Mongoose (Mapeo a Julia) ---
const MG_EV_HTTP_MSG = Cint(11) # This is the main one for full requests

# Punteros a estructuras C.
const PTR_MG_MGR = Ptr{Cvoid}
const PTR_MG_CONNECTION = Ptr{Cvoid}
const PTR_MG_EVENT_HANDLER_T = Ptr{Cvoid} # Tipo de la función de callback de eventos de Mongoose

# --- Wrapper de Funciones C de Mongoose ---
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
function get_http_message(ev_data::Ptr{Cvoid})::MgHttpMessage
    if ev_data == C_NULL
        error("ev_data for HTTP message is NULL")
    end
    return unsafe_load(Ptr{MgHttpMessage}(ev_data))
end

# --- 4. Enrutamiento en Julia ---
# Esto será un diccionario simple de rutas a funciones Julia
struct Router
    routes::Dict{Tuple{Symbol, String}, Function}
    Router() = new(Dict{Tuple{Symbol, String}, Function}())
end

const ROUTER = Router()

"""
    add_route!(router::Router, method::Symbol, path::String, handler::Function)

Agrega una ruta al router.
"""
function add_route!(method::Symbol, path::String, handler::Function)
    ROUTER.routes[(method, path)] = handler
end

function not_found_handler(c::PTR_MG_CONNECTION)
    mg_http_reply(
        c,
        Cint(404),
        Base.unsafe_convert(Cstring, "Content-Type: text/plain\r\n"), # Still good to send headers
        Base.unsafe_convert(Cstring, "404 Not Found")
    )
end

function internal_server_error_handler(c::PTR_MG_CONNECTION)
    mg_http_reply(
        c,
        Cint(500),
        Base.unsafe_convert(Cstring, "Content-Type: text/plain\r\n"),
        Base.unsafe_convert(Cstring, "500 Internal Server Error")
    )
end

# --- 5. El Callback Principal de Mongoose ---
# PTR_MG_EVENT_HANDLER_T espera (struct mg_connection *c, int ev, void *ev_data, void *fn_data)
# fn_data es opcional, lo usamos para pasar cualquier cosa a nuestro handler.
function mongoose_event_handler(c::PTR_MG_CONNECTION, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    # This println is good for general debugging, but can be verbose.
    # println("Event: $ev (Raw), Conn: $c, EvData: $ev_data")

    if ev == MG_EV_HTTP_MSG
        http_msg = get_http_message(ev_data)
        uri = unsafe_string(pointer(http_msg.uri.ptr), http_msg.uri.len)
        method = unsafe_string(pointer(http_msg.method.ptr), http_msg.method.len)
        # query = unsafe_string(pointer(http_msg.query.ptr), http_msg.query.len)
        # body = unsafe_string(http_msg.body.ptr, http_msg.body.len)

        # @info "Handling $method request for: $uri (Event Type: MG_EV_HTTP_MSG)"

        # Your existing routing logic for ROUTES
        handler = get(ROUTER.routes, (Symbol(method), uri), nothing)
        if isnothing(handler)
            return not_found_handler(c)
            @warn "404 Not Found: $method $uri"
        end
        try
            handler(c)
        catch e
            @error "Error handling request: $e"
            Base.showerror(stderr, e, catch_backtrace())
            internal_server_error_handler(c)
        end
    end
    return
end

# Crear el puntero a la función Julia que se pasará a Mongoose
# `@cfunction` solo funciona con funciones de nivel superior.
# const C_MONGOOSE_HANDLER = @cfunction(mongoose_event_handler, Cvoid, (PTR_MG_CONNECTION, Cint, Ptr{Cvoid}, Ptr{Cvoid}))

# --- 6. Función para Iniciar el Servidor ---
mutable struct ServerState
    mgr::PTR_MG_MGR
    listener::PTR_MG_CONNECTION
    is_running::Bool
    task::Union{Task, Nothing}
end

const SERVER_STATE = ServerState(C_NULL, C_NULL, false, nothing)

function start_server(port::Int=8080)::Nothing
    if SERVER_STATE.is_running
        println("Server already running.")
        return
    end

    mgr_ptr = Libc.malloc(Csize_t(128)) # Damos un poco de espacio extra

    mg_mgr_init(mgr_ptr)
    SERVER_STATE.mgr = mgr_ptr
    println("Mongoose manager initialized.")

    C_MONGOOSE_HANDLER = @cfunction(mongoose_event_handler, Cvoid, (PTR_MG_CONNECTION, Cint, Ptr{Cvoid}, Ptr{Cvoid}))

    listen_url = "http://0.0.0.0:$port"
    listener_conn = mg_http_listen(SERVER_STATE.mgr, Cstring(pointer(listen_url)), C_MONGOOSE_HANDLER, C_NULL)

    if listener_conn == C_NULL
        # Si la escucha falla, debemos limpiar aquí mismo.
        Libc.free(mgr_ptr)
        # mg_mgr_free NO es necesario porque el manager no llegó a usarse.
        println(stderr, "Mongoose failed to listen on $listen_url. errno: $(Libc.errno())")
        error("Failed to start server.")
    end

    SERVER_STATE.listener = listener_conn
    println("Listening on $listen_url")

    SERVER_STATE.is_running = true

    # Ejecutar el bucle de eventos en una tarea asíncrona
    SERVER_STATE.task = @async begin
        try
            while SERVER_STATE.is_running
                # println("Polling Mongoose...")
                mg_mgr_poll(SERVER_STATE.mgr, Cint(1)) # Poll cada 1000ms
                # println("Poll complete.")
                yield()
            end
        catch e
            if !isa(e, InterruptException)
                println(stderr, "Server loop error: $e")
                Base.showerror(stderr, e, catch_backtrace())
            end
        end
        println("Event loop task finished.")
    end
    println("Server started in background task.")
    return
end

# --- 7. Función para Detener el Servidor (Modificada) ---
function stop_server()::Nothing
    if SERVER_STATE.is_running
        println("Stopping server...")
        SERVER_STATE.is_running = false

        # Espera a que el bucle de eventos termine
        if SERVER_STATE.task !== nothing
            println("Waiting for event loop to exit...")
            wait(SERVER_STATE.task)
            SERVER_STATE.task = nothing # Limpia la referencia a la tarea
        end

        # Limpieza en el orden correcto
        if SERVER_STATE.mgr != C_NULL
            println("Freeing Mongoose manager and closing connections...")
            # 1. Decirle a Mongoose que libere todo (sockets, conexiones, etc.)
            mg_mgr_free(SERVER_STATE.mgr)
            # 2. Liberar la memoria del puntero que asignamos con malloc
            Libc.free(SERVER_STATE.mgr)
            # 3. Marcar como nulo para evitar doble liberación
            SERVER_STATE.mgr = C_NULL
        end
        println("Server stopped successfully.")
    else
        println("Server not running.")
    end
    return
end

end
