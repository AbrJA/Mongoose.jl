module Mongoose

using ConcurrentCollections
using Mongoose_jll

export Server, Request, Response, start!, stop!, register!

include("wrappers.jl")
include("structs.jl")

const VALID_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE"]

# --- 4. Request Handler Registration ---
"""
    register!(method::String, uri::AbstractString, handler::Function; server::Server = default_server())
    Registers an HTTP request handler for a specific method and URI.
    # Arguments
    - `handler::Function`: The Julia function to be called when a matching request arrives.
    - `method::AbstractString`: The HTTP method (e.g., GET, POST, PUT, PATCH, DELETE).
    - `uri::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
    - `server::Server = default_server()`: The server to register the handler with.
    This function should accept a `Request` object as its first argument, followed by any additional keyword arguments.
"""
function register!(handler::Function, method::AbstractString, uri::AbstractString; server::Server = default_server())
    method = uppercase(method)
    if !(method in VALID_METHODS)
        error("Invalid HTTP method: $method. Valid methods are: $(VALID_METHODS)")
    end
    if occursin(':', uri)
        regex = Regex("^" * replace(uri, r":([a-zA-Z0-9_]+)" => s"(?P<\1>[^/]+)") * "\$")
        if !haskey(server.router.dynamic, regex)
            server.router.dynamic[regex] = Route()
        end
        server.router.dynamic[regex].handlers[method] = handler
    else
        if !haskey(server.router.static, uri)
            server.router.static[uri] = Route()
        end
        server.router.static[uri].handlers[method] = handler
    end
    return
end

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
    key = Int(mg_conn_get_fn_data(conn))
    server = SERVER_REGISTRY[key]
    router = server.router
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

const SERVER = Ref{Server}()

function default_server()
    if !isassigned(SERVER)
        SERVER[] = Server()
    end
    return SERVER[]
end

function setup_listener!(server::Server, host::AbstractString, port::Integer)
    server.handler = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    # MAYBE: Put this in the constructor
    url = "http://$host:$port"
    fn_data = register(server)
    listener = mg_http_listen(server.manager.ptr, url, server.handler, fn_data)
    if listener == C_NULL
        cleanup!(server)
        err = Libc.errno()
        error("Failed to start server on $url (errno: $err)")
    end
    server.listener = listener
    @info "Listening on $url"
    return
end

function start_event_loop!(server::Server)
    server.master = @async begin
        try
            @info "Starting server event loop task."
            while server.running
                mg_mgr_poll(server.manager.ptr, server.timeout)
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

function worker_loop!(server::Server, worker_index::Int, router::Router)
    # router is passed in to avoid repeated access to mg_global_router()
    @info "Worker thread $worker_index started on thread $(Threads.threadid())"
    while server.running
        try
            # 1. Wait for and get a request
            request = popfirst!(server.requests)
            conn = server.connections[request.id]
            # Check for sentinel value to signal shutdown
            if request.id == -1
                break
            end
            # 2. Process the request (handle the routing)
            handle_request!(server, conn, request, router)
        catch e
            if !server.running
                break # Normal exit for shutdown
            else
                @error "Worker thread error: $e" exception=(e, catch_backtrace())
            end
        end
    end
    @info "Worker thread $worker_index finished"
    return
end

function start_worker_threads!(server::Server)
    # 1. Setup
    router = mg_global_router()
    resize!(server.workers, server.num_workers)
    # 2. Spawning Workers
    for i in eachindex(server.workers)
        server.workers[i] = Threads.@spawn worker_loop!(server, i, router)
    end
    # Return value remains simple, indicating setup is complete
    return
end

function wait_and_stop!(server::Server)
    try
        wait(server.master)
    catch e
        if !isa(e, InterruptException)
            @error "Error while waiting for server" exception = (e, catch_backtrace())
        end
    finally
        stop!(server)
    end
    return
end

# --- 6. Server Management ---
"""
    start!(; server::Server = default_server(), host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true)

    Starts the Mongoose HTTP server. Initialize the Mongoose manager, binds an HTTP listener, and starts a background Task to poll the Mongoose event loop.

    Arguments
    - `server::Server = default_server()`: The server object to start. If not provided, the default server is used.
    - `host::AbstractString="127.0.0.1"`: The IP address or hostname to listen on. Defaults to "127.0.0.1" (localhost).
    - `port::Integer=8080`: The port number to listen on. Defaults to 8080.
    - `async::Bool=true`: If true, runs the server in a non-blocking mode. If false, blocks until the server is stopped.
"""
function start!(; server::Server = default_server(), host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true)
    !server.running || (@warn "Server already running."; return)
    @info "Starting server..."
    server.manager = Manager()
    setup_listener!(server, host, port)
    server.running = true
    start_event_loop!(server)
    @info "Server started successfully."
    async || wait_and_stop!(server)
    return
end

"""
    stop!(; server::Server = default_server())
    Stops the running Mongoose HTTP server. Sets a flag to stop the background event loop task, and then frees the Mongoose associated resources.
    Arguments
    - `server::Server = default_server()`: The server object to shutdown. If not provided, the default server is used.
"""
function stop!(server::Server = default_server())
    if server.running
        @info "Stopping server..."
        server.running = false
        if !isnothing(server.master)
            wait(server.master)
            server.master = nothing
        end
        cleanup!(server)
        @info "Server stopped successfully."
    else
        @warn "Server not running."
    end
    return
end

end
