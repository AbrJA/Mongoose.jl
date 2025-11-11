module Mongoose

using Mongoose_jll

export Request, Response, serve, shutdown, register

include("wrappers.jl")
include("structs.jl")
include("routes.jl")

function route_handler(request::IdRequest, route::Route; kwargs...)
    method = request.payload.method
    if haskey(route.handlers, method)
            try
                response = route.handlers[method](request.payload; kwargs...)
                return IdResponse(request.id, response)
            catch e # CHECK THIS TO ALWAYS RESPOND
                @error "Route handler failed to execute" exception = (e, catch_backtrace())
                response = Response(500, Dict("Content-Type" => "text/plain"), "500 Internal Server Error")
                return IdResponse(request.id, response)
            end
    else
        @warn "405 Method Not Allowed: $method"
        response = Response(405, Dict("Content-Type" => "text/plain"), "405 Method Not Allowed")
        return IdResponse(request.id, response)
    end
end

# --- 5. Event handling ---
function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    # ev != MG_EV_POLL && @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data"
    if ev !== MG_EV_HTTP_MSG
        return
    end
    router = global_router()
    message = MgHttpMessage(ev_data)
    request = IdRequest(Int(conn), Request(message))
    uri = request.payload.uri
    route = get(router.static, uri, nothing)
    if !isnothing(route)
        response = route_handler(request, route)
        return mg_http_reply(conn, response.payload.status, to_string(response.payload.headers), response.payload.body)
    end
    for (regex, route) in router.dynamic
        matched = match(regex, uri)
        if !isnothing(matched)
            response =  route_handler(request, route; params = matched)
            return mg_http_reply(conn, response.payload.status, to_string(response.payload.headers), response.payload.body)
        end
    end
    @warn "404 Not Found: $uri"
    return mg_http_reply(conn, 404, to_string(Dict("Content-Type" => "text/plain")), "404 Not Found")
end

# Instead of manual malloc, consider using finalizers
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
    running::Bool

    function Server(log_level::Integer = 0)
        mg_log_set_level(log_level)
        return new(Manager(), C_NULL, C_NULL, nothing, false)
    end
end

const SERVER = Ref{Server}()

function global_server()
    if !isassigned(SERVER)
        SERVER[] = Server()
    end
    return SERVER[]
end

function setup_listener!(server::Server, host::AbstractString, port::Integer)
    server.handler = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    # MAYBE: Put this in the constructor
    url = "http://$host:$port"
    listener = mg_http_listen(server.manager.ptr, url, server.handler, C_NULL)
    if listener == C_NULL
        mgr_cleanup!(server.manager)
        err = Libc.errno()
        @error "Mongoose failed to listen on $url. errno: $err"
        error("Failed to start server. (errno: $err)")
    end
    server.listener = listener
    @info "Listening on $url"
    return
end

function start_event_loop!(server::Server, timeout::Integer)
    server.task = @async begin
        try
            @info "Starting server event loop task."
            while server.running
                mg_mgr_poll(server.manager.ptr, timeout)
                yield()
            end
        catch e
            if !isa(e, InterruptException)
                @error "Server event loop error" exception = (e, catch_backtrace())
            end
        finally
            # The loop has stopped, either by clean shutdown or error
            @info "Server event loop task finished."
        end
    end
    return
end

function wait_and_shutdown!(server::Server)
    try
        wait(server.task)
    catch e
        if !isa(e, InterruptException)
            @error "Error while waiting for server task" exception = (e, catch_backtrace())
        end
    finally
        shutdown!()
    end
    return
end

# --- 6. Server Management ---
"""
    serve(; host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true, timeout::Integer = 0)

    Starts the Mongoose HTTP server. Initialize the Mongoose manager, binds an HTTP listener, and starts a background Task to poll the Mongoose event loop.

    Arguments
    - `host::AbstractString="127.0.0.1"`: The IP address or hostname to listen on. Defaults to "127.0.0.1" (localhost).
    - `port::Integer=8080`: The port number to listen on. Defaults to 8080.
    - `async::Bool=true`: If true, runs the server in a non-blocking mode. If false, blocks until the server is stopped.
    - `timeout::Integer=0`: The timeout value in milliseconds for the event loop. Defaults to 0 (no timeout).
"""
function serve(; host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true, timeout::Integer = 0)
    server = global_server()
    if server.running
        @warn "Server already running."
        return
    end
    @info "Starting server..."
    server.manager = Manager()
    setup_listener!(server, host, port)
    server.running = true
    start_event_loop!(server, timeout)
    @info "Server started successfully."
    if !async
        wait_and_shutdown!(server)
    end
    return
end

"""
    shutdown()

    Stops the running Mongoose HTTP server. Sets a flag to stop the background event loop task, and then frees the Mongoose associated resources.
"""
function shutdown()
    server = global_server()
    if server.running
        @info "Stopping server..."
        server.running = false
        if !isnothing(server.task)
            wait(server.task)
            server.task = nothing
        end
        mgr_cleanup!(server.manager)
        @info "Server stopped successfully."
    else
        @warn "Server not running."
    end
    return
end

end
