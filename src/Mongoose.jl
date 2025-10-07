module Mongoose

using Mongoose_jll
using Base.Threads

export MgConnection, MgHttpMessage, MgRequest, MgResponse,
       mg_serve!, mg_shutdown!,
       mg_register!,
       mg_method, mg_uri, mg_query, mg_proto, mg_body, mg_message, mg_headers,
       mg_http_reply, mg_json_reply, mg_text_reply,
       MgThreadPoolServer,
       mg_serve_threaded!, mg_shutdown_threaded!

include("wrappers.jl")
include("structs.jl")
include("routes.jl")
include("threaded.jl")

function mg_route_handler(conn::Ptr{Cvoid}, method::Symbol, route::MgRoute; kwargs...)
    if haskey(route.handlers, method)
            try
                return route.handlers[method](conn; kwargs...)
            catch e # CHECK THIS TO ALWAYS RESPOND
                @error "Route handler error: $e" error = (e, catch_backtrace())
                return mg_text_reply(conn, 500, "500 Internal Server Error")
            end
    else
        @warn "405 Method Not Allowed: $method"
        return mg_text_reply(conn, 405, "405 Method Not Allowed")
    end
end

# --- 5. Event handling ---
function mg_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    # @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data, FnData: $fn_data"
    if ev !== MG_EV_HTTP_MSG
        return
    end
    router = mg_global_router()
    message = mg_http_message(ev_data)
    uri = mg_uri(message)
    method = Symbol(mg_method(message))
    route = get(router.static, uri, nothing)
    if !isnothing(route)
        return mg_route_handler(conn, method, route; message = message)
    end
    for (regex, route) in router.dynamic
        matched = match(regex, uri)
        if !isnothing(matched)
            return mg_route_handler(conn, method, route; message = message, params = matched)
        end
    end
    @warn "404 Not Found: $uri"
    return mg_text_reply(conn, 404, "404 Not Found")
end

# Instead of manual malloc, consider using finalizers
mutable struct MgManager
    ptr::Ptr{Cvoid}
    function MgManager()
        ptr = Libc.malloc(Csize_t(128))
        ptr == C_NULL && error("Failed to allocate manager memory")
        mg_mgr_init!(ptr)
        mgr = new(ptr)
        finalizer(mg_mgr_cleanup!, mgr)
        return mgr
    end
end

function mg_mgr_cleanup!(mgr::MgManager)
    if mgr.ptr != C_NULL
        mg_mgr_free!(mgr.ptr)
        Libc.free(mgr.ptr)
        mgr.ptr = C_NULL
    end
end

mutable struct MgServer
    mgr::MgManager
    listener::Ptr{Cvoid}
    running::Bool
    task::Union{Task, Nothing}
end

const MG_SERVER = Ref{MgServer}()

function mg_global_server()::MgServer
    if !isassigned(MG_SERVER)
        MG_SERVER[] = MgServer(MgManager(), C_NULL, false, nothing)
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
    - `async::Bool=true`: If true, runs the server in a non-blocking mode. If false, blocks until the server is stopped.
"""
function mg_serve!(; host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true)::Nothing
    server = mg_global_server()
    if server.running
        @warn "Server already running."
        return
    end
    @info "Starting server..."
    ptr_mg_event_handler = @cfunction(mg_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    url = "http://$host:$port"
    listener = mg_http_listen(server.mgr.ptr, url, ptr_mg_event_handler, C_NULL)
    if listener == C_NULL
        mg_mgr_cleanup!(server.mgr)
        @error "Mongoose failed to listen on $url. errno: $(Libc.errno())"
        error("Failed to start server.")
    end
    server.listener = listener
    @info "Listening on $url"
    server.running = true
    server.task = @async begin
        try
            while server.running
                mg_mgr_poll(server.mgr.ptr, 1)
                yield()
            end
        catch e
            if !isa(e, InterruptException)
                @error "Server loop error: $e" error = (e, catch_backtrace())
            end
        end
        @info "Event loop task finished."
    end
    @info "Server started successfully."
    if !async
        try
            wait(server.task)
        catch e
            if !isa(e, InterruptException)
                @error "Server task error: $e" error = (e, catch_backtrace())
            end
        finally
            mg_shutdown!()
        end
    end
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
            wait(server.task)
            server.task = nothing
        end
        mg_mgr_cleanup!(server.mgr)
        @info "Server stopped successfully."
    else
        @warn "Server not running."
    end
    return
end

end
