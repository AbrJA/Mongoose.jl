module Mongoose

using Libdl # Para dlopen, etc.

# --- 1. Configuración y Ruta de la Librería ---
const SCRIPT_DIR = @__DIR__
const LIB_MONGOOSE = joinpath(SCRIPT_DIR, "libmongoose.so")

# --- 2. Constantes y Tipos Mongoose (Mapeo a Julia) ---
const MG_EV_HTTP_MSG    = Cint(11) # This is the main one for full requests

# Punteros a estructuras C.
const Ptr_mg_mgr = Ptr{Cvoid}
const Ptr_mg_connection = Ptr{Cvoid}
const Ptr_mg_http_message = Ptr{Cvoid} # Para el ev_data en MG_EV_HTTP_MSG

# Tipo de la función de callback de eventos de Mongoose
const mg_event_handler_t = Ptr{Cvoid} # Cuando se pasa a @ccall

# --- 3. Wrapper de Funciones C de Mongoose ---
# Función para inicializar el manager de Mongoose
function mg_mgr_init(mgr::Ptr_mg_mgr)
    @ccall LIB_MONGOOSE.mg_mgr_init(mgr::Ptr_mg_mgr)::Cvoid
end

# Función para escuchar conexiones HTTP
# mg_http_listen(mgr, url, handler, userdata)
function mg_http_listen(mgr::Ptr_mg_mgr, url::Cstring, handler::mg_event_handler_t, userdata::Ptr{Cvoid})::Ptr_mg_connection
    @ccall LIB_MONGOOSE.mg_http_listen(mgr::Ptr_mg_mgr, url::Cstring, handler::mg_event_handler_t, userdata::Ptr{Cvoid})::Ptr_mg_connection
end

# Función para procesar eventos
# mg_mgr_poll(mgr, timeout_ms)
function mg_mgr_poll(mgr::Ptr_mg_mgr, timeout_ms::Cint)::Cint
    @ccall LIB_MONGOOSE.mg_mgr_poll(mgr::Ptr_mg_mgr, timeout_ms::Cint)::Cint
end

# Función para responder a una petición HTTP
# mg_http_reply(c, status, headers, body)
function mg_http_reply(c::Ptr_mg_connection, status::Cint, headers::Cstring, body::Cstring)
    @ccall LIB_MONGOOSE.mg_http_reply(c::Ptr_mg_connection, status::Cint, headers::Cstring, body::Cstring)::Cvoid
end

function mg_mgr_free(mgr::Ptr_mg_mgr)
    @ccall LIB_MONGOOSE.mg_mgr_free(mgr::Ptr_mg_mgr)::Cvoid
end

struct mg_str
    ptr::Cstring # Puntero al inicio de la cadena
    len::Csize_t # Longitud de la cadena
end

const MG_MAX_HTTP_HEADERS = 30 # <-- VERIFICA ESTE VALOR EN TU mongoose.h

struct mg_http_header
    name::mg_str
    val::mg_str
end

# Función para obtener la URI de una petición HTTP
struct mg_http_message
    method::mg_str
    uri::mg_str
    query::mg_str
    proto::mg_str
    headers::NTuple{MG_MAX_HTTP_HEADERS, mg_http_header} # Array of headers
    body::mg_str
    head::mg_str
    message::mg_str
end

# Ahora podemos acceder a la URI de mg_http_message
function get_http_message(ev_data::Ptr{Cvoid})::mg_http_message
    if ev_data == C_NULL
        error("ev_data for HTTP message is NULL")
    end
    return unsafe_load(Ptr{mg_http_message}(ev_data))
end

# --- 4. Enrutamiento en Julia ---
# Esto será un diccionario simple de rutas a funciones Julia
const ROUTES = Dict{String, Function}()

# Registra una función para una ruta específica
function register_route(path::String, handler::Function)
    ROUTES[path] = handler
end

# Funciones de handler de ejemplo
function hello_world_handler(conn_ptr::Ptr_mg_connection)
    mg_http_reply(
        conn_ptr,
        Cint(200),
        Base.unsafe_convert(Cstring, "Content-Type: text/plain\r\n"),
        Base.unsafe_convert(Cstring, "Hello World from Julia!")
    )
end

function not_found_handler(conn_ptr::Ptr_mg_connection)
    mg_http_reply(
        conn_ptr,
        Cint(404),
        Base.unsafe_convert(Cstring, "Content-Type: text/plain\r\n"), # Still good to send headers
        Base.unsafe_convert(Cstring, "404 Not Found")
    )
end

# --- 5. El Callback Principal de Mongoose ---
# mg_event_handler_t espera (struct mg_connection *c, int ev, void *ev_data, void *fn_data)
# fn_data es opcional, lo usamos para pasar cualquier cosa a nuestro handler.
function mongoose_event_handler(c::Ptr_mg_connection, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    # This println is good for general debugging, but can be verbose.
    # println("Event: $ev (Raw), Conn: $c, EvData: $ev_data")

    if ev == MG_EV_HTTP_MSG
        http_msg = get_http_message(ev_data)
        uri = unsafe_string(pointer(http_msg.uri.ptr), http_msg.uri.len)
        method = unsafe_string(pointer(http_msg.method.ptr), http_msg.method.len)

        # println("Handling $method request for: $uri (Event Type: MG_EV_HTTP_MSG)")

        # Your existing routing logic for ROUTES
        if haskey(ROUTES, uri)
            ROUTES[uri](c)
        else
            not_found_handler(c)
        end
    end
end

# Crear el puntero a la función Julia que se pasará a Mongoose
# `@cfunction` solo funciona con funciones de nivel superior.
const C_MONGOOSE_HANDLER = @cfunction(mongoose_event_handler, Cvoid, (Ptr_mg_connection, Cint, Ptr{Cvoid}, Ptr{Cvoid}))

# --- 6. Función para Iniciar el Servidor ---
mutable struct ServerState
    mgr::Ptr_mg_mgr
    listener::Ptr_mg_connection
    is_running::Bool
    task::Union{Task, Nothing}
end

const global_server_state = ServerState(C_NULL, C_NULL, false, nothing)

function start_server(port::Int=8080)
    if global_server_state.is_running
        println("Server already running.")
        return
    end

    mgr_ptr = Libc.malloc(Csize_t(128)) # Damos un poco de espacio extra

    mg_mgr_init(mgr_ptr)
    global_server_state.mgr = mgr_ptr
    println("Mongoose manager initialized.")

    # Registrar las rutas de ejemplo
    register_route("/hello", hello_world_handler)
    # register_route("/echo", (c, body) -> echo_handler(c, body)) # El handler de echo necesita el cuerpo

    listen_url = "http://0.0.0.0:$port"
    listener_conn = mg_http_listen(global_server_state.mgr, Cstring(pointer(listen_url)), C_MONGOOSE_HANDLER, C_NULL)

    if listener_conn == C_NULL
        # Si la escucha falla, debemos limpiar aquí mismo.
        Libc.free(mgr_ptr)
        # mg_mgr_free NO es necesario porque el manager no llegó a usarse.
        println(stderr, "Mongoose failed to listen on $listen_url. errno: $(Libc.errno())")
        error("Failed to start server.")
    end

    global_server_state.listener = listener_conn
    println("Listening on $listen_url")

    global_server_state.is_running = true

    # Ejecutar el bucle de eventos en una tarea asíncrona
    global_server_state.task = @async begin
        try
            while global_server_state.is_running
                # println("Polling Mongoose...")
                mg_mgr_poll(global_server_state.mgr, Cint(1)) # Poll cada 1000ms
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
function stop_server()
    if global_server_state.is_running
        println("Stopping server...")
        global_server_state.is_running = false

        # Espera a que el bucle de eventos termine
        if global_server_state.task !== nothing
            println("Waiting for event loop to exit...")
            wait(global_server_state.task)
            global_server_state.task = nothing # Limpia la referencia a la tarea
        end

        # Limpieza en el orden correcto
        if global_server_state.mgr != C_NULL
            println("Freeing Mongoose manager and closing connections...")
            # 1. Decirle a Mongoose que libere todo (sockets, conexiones, etc.)
            mg_mgr_free(global_server_state.mgr)
            # 2. Liberar la memoria del puntero que asignamos con malloc
            Libc.free(global_server_state.mgr)
            # 3. Marcar como nulo para evitar doble liberación
            global_server_state.mgr = C_NULL
        end
        println("Server stopped successfully.")
    else
        println("Server not running.")
    end
end

end
