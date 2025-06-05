module Mongoose

using Libdl # Para dlopen, etc.

# --- 1. Configuración y Ruta de la Librería ---
const SCRIPT_DIR = @__DIR__
const LIB_MONGOOSE = joinpath(SCRIPT_DIR, "libmongoose.so")

# --- 2. Constantes y Tipos Mongoose (Mapeo a Julia) ---
# ¡Estos valores deben coincidir exactamente con el enum de mongoose.c!
const MG_EV_ERROR       = Cint(0)
const MG_EV_OPEN        = Cint(1)
const MG_EV_POLL        = Cint(2)
const MG_EV_RESOLVE     = Cint(3)
const MG_EV_CONNECT     = Cint(4)
const MG_EV_ACCEPT      = Cint(5)
const MG_EV_TLS_HS      = Cint(6)
const MG_EV_READ        = Cint(7)
const MG_EV_WRITE       = Cint(8)
const MG_EV_CLOSE       = Cint(9)
const MG_EV_HTTP_HDRS   = Cint(10) # New: HTTP Headers event
const MG_EV_HTTP_MSG    = Cint(11) # This is the main one for full requests
const MG_EV_WS_OPEN     = Cint(12)
const MG_EV_WS_MSG      = Cint(13)
const MG_EV_WS_CTL      = Cint(14)
const MG_EV_MQTT_CMD    = Cint(15)
const MG_EV_MQTT_MSG    = Cint(16)
const MG_EV_MQTT_OPEN   = Cint(17)
const MG_EV_SNTP_TIME   = Cint(18)
const MG_EV_WAKEUP      = Cint(19)
const MG_EV_USER        = Cint(20)

# Punteros a estructuras C. No necesitamos definir la estructura completa
# a menos que necesitemos acceder a sus campos directamente en Julia.
# Mongoose a menudo te da punteros opacos que usas en otras llamadas.
const Ptr_mg_mgr = Ptr{Cvoid}
const Ptr_mg_connection = Ptr{Cvoid}
const Ptr_mg_http_message = Ptr{Cvoid} # Para el ev_data en MG_EV_HTTP_MSG

# Tipo de la función de callback de eventos de Mongoose
# typedef void (*mg_event_handler_t)(struct mg_connection *, int, void *);
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
# Mongoose 7+ usa mg_http_message.uri para la URI
# Necesitamos acceder a la estructura `mg_http_message`.
# Vamos a definir una versión simplificada de `mg_str` y `mg_http_message`
# Solo los campos que necesitamos.
# struct mg_str { const char *ptr; size_t len; };
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

function echo_handler(conn_ptr::Ptr_mg_connection, body::String)
    mg_http_reply(
        conn_ptr,
        Cint(200),
        Base.unsafe_convert(Cstring, "Content-Type: text/plain\r\n"),
        Base.unsafe_convert(Cstring, "Echo: $(body)") # Use string interpolation for body
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
    # This println is good for general debugging
    # println("Event: $ev (Raw), Conn: $c, EvData: $ev_data")

    if ev == MG_EV_HTTP_MSG
        # Only attempt to access ev_data as mg_http_message for these specific events
        if ev_data == C_NULL
            # This case should ideally not happen for MG_EV_HTTP_MSG/HDRS,
            # but it's good to have a safeguard if Mongoose behaves unexpectedly.
            println(stderr, "Warning: ev_data is NULL for HTTP_MSG/HDRS event. This should not happen. Event: $ev")
            return
        end

        http_msg = get_http_message(ev_data)
        uri = unsafe_string(pointer(http_msg.uri.ptr), http_msg.uri.len)
        method = unsafe_string(pointer(http_msg.method.ptr), http_msg.method.len)
        # And also for body, if you access it like this:
        body = unsafe_string(pointer(http_msg.body.ptr), http_msg.body.len) # In echo_handler

        println("Received $method request for: $uri (Event Type: $ev)")

        # Your existing routing logic for ROUTES
        if haskey(ROUTES, uri)
            # For POST requests, specifically for /echo, you'll need the body
            if method == "POST" && uri == "/echo"
                body = unsafe_string(http_msg.body.ptr, http_msg.body.len)
                ROUTES[uri](c, body)
            else
                ROUTES[uri](c)
            end
        else
            not_found_handler(c)
        end
    elseif ev == MG_EV_ERROR
        # For MG_EV_ERROR, ev_data is char* error_message
        if ev_data != C_NULL
            error_msg = unsafe_string(ev_data) # Attempt to read the error message
            println(stderr, "Mongoose Error: $error_msg (Event Code: $ev)")
        else
            println(stderr, "Mongoose Error: (No error message) (Event Code: $ev)")
        end
    elseif ev == MG_EV_POLL
        # For MG_EV_POLL, ev_data is uint64_t *uptime_millis
        # You could read uptime here if needed: unsafe_load(Ptr{UInt64}(ev_data))
        # println("Poll event. Uptime: $(unsafe_load(Ptr{UInt64}(ev_data))) ms")
    elseif ev == MG_EV_CLOSE
        println("Connection closed: $c")
    elseif ev == MG_EV_ACCEPT
        println("Connection accepted: $c")
    # You can add more specific handling for other events if you need them.
    else
        # For all other events where ev_data is NULL or a different type
        println("Unhandled Mongoose event: $ev")
    end
end

# Crear el puntero a la función Julia que se pasará a Mongoose
# `@cfunction` solo funciona con funciones de nivel superior.
const C_MONGOOSE_HANDLER = @cfunction(mongoose_event_handler, Cvoid,
                                      (Ptr_mg_connection, Cint, Ptr{Cvoid}, Ptr{Cvoid}))

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

    # Asignar memoria para el manager de Mongoose
    # Mongoose 7+ no requiere que asignes mg_mgr. Simplemente pasas &mgr.
    # Pero para FFI con Julia, a menudo asignamos y pasamos un puntero.
    # Una forma segura es un `Ref` si la struct mg_mgr es pequeña y simple,
    # o `Libc.malloc` para structs más complejas que son manejadas por la librería C.
    # Mongoose 7.x: `struct mg_mgr mgr; mg_mgr_init(&mgr);`
    # Esto significa que `mg_mgr` es una struct y la inicializas.
    # Si la pasamos a C como `Ptr{Cvoid}`, es mejor que la librería C la maneje,
    # o que la asignemos con `Libc.malloc` y la liberemos después.
    # Para la máxima simplicidad, podemos usar un `Ref{Cvoid}` como proxy para `mg_mgr`
    # o un `Ref{MgMgrStruct}` si definimos la struct completamente.
    # Pero el ejemplo de Mongoose simplemente declara `struct mg_mgr mgr;`
    # y pasa `&mgr`. Esto es un poco delicado con `ccall`.
    # Un puntero a una estructura sin tamaño conocido es Ptr{Cvoid}.
    # Lo más seguro es que Mongoose te dé un puntero a un `mg_mgr` que maneja internamente.
    # Sin embargo, el ejemplo C es `struct mg_mgr mgr; mg_mgr_init(&mgr);`.
    # Esto implica que `mgr` es stack-allocated.

    # Intentemos con un `Ref` a un `Cvoid` para simular un `&mgr` si Mongoose
    # realmente lo maneja como una caja negra. Esto es un hack.
    # La forma correcta sería definir `struct MongooseMgr # ... # end`
    # y luego `mgr = Ref{MongooseMgr}()` y pasar `mgr`.
    # Pero no conocemos la estructura interna de `mg_mgr`.

    # A menudo, en Mongoose, se pasa una dirección de una estructura declarada localmente.
    # En Julia, esto es complicado con `ccall`. Podemos simularla con `Libc.malloc`
    # para un tamaño aproximado, o la documentación de Mongoose podría decir el tamaño
    # de `mg_mgr`. Asumiremos que `mg_mgr` puede ser tratada como una `Ptr{Cvoid}` por ahora
    # y que Mongoose no espera un tamaño específico de asignación de Julia.
    # Sin embargo, la forma más robusta es definir `struct mg_mgr` en Julia si es accesible.

    # Por simplicidad, y basándonos en cómo Mongoose se usa a menudo,
    # el `mgr_ptr` es un puntero a una instancia de `mg_mgr` que Mongoose manipula.
    # Si no la asignamos, Mongoose podría escribir en memoria inválida.
    # Vamos a usar `Libc.malloc` para darle un lugar.
    # El tamaño real de `struct mg_mgr` es el problema.
    # Una búsqueda rápida muestra que `sizeof(struct mg_mgr)` es alrededor de 88 bytes en 64-bit.
    mgr_ptr = Libc.malloc(Csize_t(128)) # Damos un poco de espacio extra

    mg_mgr_init(mgr_ptr)
    global_server_state.mgr = mgr_ptr
    println("Mongoose manager initialized.")

    # Registrar las rutas de ejemplo
    register_route("/hello", hello_world_handler)
    register_route("/echo", (c, body) -> echo_handler(c, body)) # El handler de echo necesita el cuerpo

    listen_url = "http://0.0.0.0:$port"
    listener_conn = mg_http_listen(global_server_state.mgr, Cstring(pointer(listen_url)), C_MONGOOSE_HANDLER, C_NULL)
    if listener_conn == C_NULL
        Libc.free(global_server_state.mgr)
        error("Failed to listen on $listen_url. Is the port already in use?")
    end
    global_server_state.listener = listener_conn
    println("Listening on $listen_url")

    global_server_state.is_running = true

    # Ejecutar el bucle de eventos en una tarea asíncrona
    global_server_state.task = @async begin
        try
            while global_server_state.is_running
                # println("Polling Mongoose...")
                mg_mgr_poll(global_server_state.mgr, Cint(10)) # Poll cada 1000ms
                # println("Poll complete.")
                sleep(0.01) # Pequeña pausa para no bloquear el hilo de Julia
            end
        catch e
            if !isa(e, InterruptException)
                println(stderr, "Server loop error: $e")
                Base.showerror(stderr, e, catch_backtrace())
            end
        finally
            # Mongoose tiene mg_mgr_free para limpiar. Necesitaríamos envolverla.
            # Por ahora, solo liberamos la memoria asignada por Julia.
            # mg_mgr_free(global_server_state.mgr) # Esto sería lo ideal
            if global_server_state.mgr != C_NULL
                Libc.free(global_server_state.mgr)
                global_server_state.mgr = C_NULL
            end
            println("Mongoose resources freed.")
            global_server_state.is_running = false
        end
    end

    println("Server started in background task. Press Ctrl+C to stop.")
    return
end

function stop_server()
    if global_server_state.is_running
        println("Stopping server...")
        global_server_state.is_running = false
        # No hay una función mg_stop_listen o mg_close para un listener específico
        # en las versiones más simples de Mongoose directamente callable.
        # Al detener el bucle de mg_mgr_poll y liberar el mgr, debería parar.
        if global_server_state.task !== nothing
            wait(global_server_state.task) # Esperar a que la tarea termine
        end
        println("Server stopped.")
    else
        println("Server not running.")
    end
end

end
