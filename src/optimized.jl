module Mongoose

using Libdl

# --- 1. Configuración ---
const SCRIPT_DIR = @__DIR__
const LIB_MONGOOSE = joinpath(SCRIPT_DIR, "libmongoose.so")

# --- 2. Constantes y Tipos Mongoose ---
const MG_EV_HTTP_MSG = Cint(11)
const Ptr_mg_mgr = Ptr{Cvoid}
const Ptr_mg_connection = Ptr{Cvoid}

# --- Constantes para Respuestas HTTP (Optimizacion #2) ---
const HTTP_HEADER_PLAIN = "Content-Type: text/plain\r\n\0"
const HTTP_BODY_HELLO   = "Hello World from Julia!\0"
const HTTP_BODY_NOTFOUND = "404 Not Found\0"

const CSTR_HEADER_PLAIN = Cstring(pointer(HTTP_HEADER_PLAIN))
const CSTR_BODY_HELLO   = Cstring(pointer(HTTP_BODY_HELLO))
const CSTR_BODY_NOTFOUND = Cstring(pointer(HTTP_BODY_NOTFOUND))

# --- Constantes para Rutas (Optimizacion #1) ---
const ROUTE_HELLO = "/hello"
const ROUTE_HELLO_LEN = Csize_t(length(ROUTE_HELLO))

# --- 3. Structs de Mongoose ---
struct mg_str
    ptr::Ptr{Cchar}
    len::Csize_t
end

struct mg_http_message
    method::mg_str
    uri::mg_str
    # ... otros campos si los necesitas ...
end

# --- 4. Wrappers de Funciones C ---
function mg_mgr_init(mgr::Ptr_mg_mgr); @ccall LIB_MONGOOSE.mg_mgr_init(mgr::Ptr_mg_mgr)::Cvoid; end
function mg_http_listen(mgr::Ptr_mg_mgr, url::Cstring, handler, userdata::Ptr{Cvoid}); @ccall LIB_MONGOOSE.mg_http_listen(mgr::Ptr_mg_mgr, url::Cstring, handler::Ptr{Cvoid}, userdata::Ptr{Cvoid})::Ptr_mg_connection; end
function mg_mgr_poll(mgr::Ptr_mg_mgr, timeout_ms::Cint); @ccall LIB_MONGOOSE.mg_mgr_poll(mgr::Ptr_mg_mgr, timeout_ms::Cint)::Cint; end
function mg_http_reply(c::Ptr_mg_connection, status::Cint, headers::Cstring, body::Cstring); @ccall LIB_MONGOOSE.mg_http_reply(c::Ptr_mg_connection, status::Cint, headers::Cstring, body::Cstring)::Cvoid; end
function mg_mgr_free(mgr::Ptr_mg_mgr); @ccall LIB_MONGOOSE.mg_mgr_free(mgr::Ptr_mg_mgr)::Cvoid; end

# --- 5. Handlers de Julia (optimizados) ---
function hello_world_handler(conn_ptr::Ptr_mg_connection)
    mg_http_reply(conn_ptr, Cint(200), CSTR_HEADER_PLAIN, CSTR_BODY_HELLO)
end

function not_found_handler(conn_ptr::Ptr_mg_connection)
    mg_http_reply(conn_ptr, Cint(404), CSTR_HEADER_PLAIN, CSTR_BODY_NOTFOUND)
end

# --- 6. Callback Principal (optimizado) ---
function mongoose_event_handler(c::Ptr_mg_connection, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    if ev == MG_EV_HTTP_MSG
        # Accedemos directamente a los campos, sin `unsafe_load` del struct completo
        http_msg_ptr = Ptr{mg_http_message}(ev_data)
        uri_ptr = unsafe_load(Ptr{Ptr{Cchar}}(Base.unsafe_convert(Ptr{UInt8}, http_msg_ptr) + fieldoffset(mg_http_message, 2)))
        uri_len = unsafe_load(Ptr{Csize_t}(Base.unsafe_convert(Ptr{UInt8}, http_msg_ptr) + fieldoffset(mg_http_message, 2) + sizeof(Ptr)))

        # Enrutamiento sin alocaciones (Optimizacion #1)
        if uri_len == ROUTE_HELLO_LEN &&
           ccall(:memcmp, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), uri_ptr, ROUTE_HELLO, ROUTE_HELLO_LEN) == 0
            hello_world_handler(c)
        else
            not_found_handler(c)
        end
    end
    return
end

const C_MONGOOSE_HANDLER = @cfunction(mongoose_event_handler, Cvoid, (Ptr_mg_connection, Cint, Ptr{Cvoid}, Ptr{Cvoid}))

# --- 7. Control del Servidor ---
mutable struct ServerState
    mgr::Ptr_mg_mgr
    is_running::Bool
    task::Union{Task, Nothing}
end

const global_server_state = ServerState(C_NULL, false, nothing)

function start_server(port::Int=8080)
    if global_server_state.is_running
        println("Server already running.")
        return
    end

    mgr = Libc.malloc(4096) # Tamaño seguro para mg_mgr, Mongoose recomienda unos pocos KB
    mg_mgr_init(mgr)

    listen_url = "http://0.0.0.0:$port"
    listener = mg_http_listen(mgr, Cstring(pointer(listen_url)), C_MONGOOSE_HANDLER, C_NULL)
    if listener == C_NULL
        mg_mgr_free(mgr)
        Libc.free(mgr)
        error("Failed to listen on $listen_url.")
    end

    global_server_state.mgr = mgr
    global_server_state.is_running = true
    println("Server listening on $listen_url")

    # Bucle de eventos optimizado (Optimizacion #3)
    global_server_state.task = @async begin
        while global_server_state.is_running
            mg_mgr_poll(global_server_state.mgr, Cint(1))
            yield()
        end
        println("Event loop finished.")
    end

    println("Server started. Press Ctrl+C in console to stop.")
end

function stop_server()
    if global_server_state.is_running
        println("Stopping server...")
        global_server_state.is_running = false

        if global_server_state.task !== nothing
            wait(global_server_state.task)
        end

        # Limpieza correcta (Optimizacion #4)
        if global_server_state.mgr != C_NULL
            mg_mgr_free(global_server_state.mgr)
            Libc.free(global_server_state.mgr)
            global_server_state.mgr = C_NULL
        end
        println("Server stopped and resources freed.")
    else
        println("Server not running.")
    end
end

end # Fin del módulo