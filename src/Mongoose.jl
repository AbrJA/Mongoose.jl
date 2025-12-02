module Mongoose

using Mongoose_jll

export AsyncServer, SyncServer, Request, Response, start!, shutdown!, route!

include("wrappers.jl")
include("handlers.jl")
include("routes.jl")
include("events.jl")
include("servers.jl")
include("registry.jl")

const VALID_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE"]

"""
    route!(server::Server, method::String, uri::AbstractString, handler::Function)
    Registers an HTTP request handler for a specific method and URI.
    # Arguments
    - `server::Server`: The server to register the handler with.
    - `method::AbstractString`: The HTTP method (e.g., GET, POST, PUT, PATCH, DELETE).
    - `uri::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
    - `handler::Function`: The Julia function to be called when a matching request arrives.
    This function should accept a `Request` object as its first argument, followed by any additional keyword arguments.
"""
function route!(server::Server, method::AbstractString, uri::AbstractString, handler::Function)
    method = uppercase(method)
    if !(method in VALID_METHODS)
        error("Invalid HTTP method: $method. Valid methods are: $(VALID_METHODS)")
    end
    if occursin(':', uri)
        regex = Regex('^' * replace(uri, r":([a-zA-Z0-9_]+)" => s"(?P<\1>[^/]+)") * '\$')
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

# --- 6. Server Management ---
"""
    start!(server::Server; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=false)

    Starts the Mongoose HTTP server. Initialize the Mongoose manager, binds an HTTP listener, and starts a background Task to poll the Mongoose event loop.

    Arguments
    - `server::Server`: The server object to start.
    - `host::AbstractString="127.0.0.1"`: The IP address or hostname to listen on. Defaults to "127.0.0.1" (localhost).
    - `port::Integer=8080`: The port number to listen on. Defaults to 8080.
    - `blocking::Bool=true`: If true, blocks until the server is stopped. If false, runs the server in a non-blocking mode.
"""
function start!(server::Server; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=true)
    if server.running
        @info "Server already running. Nothing to do."
        return
    end
    @info "Starting server..."
    server.running = true
    try
        register!(server)
        setup_resources!(server)
        setup_listener!(server, host, port)
        start_workers!(server)
        start_master!(server)
        blocking && run_blocking!(server)
    catch e
        rethrow(e)
        shutdown!(server)
    end
    return
end

"""
    shutdown!(server::Server)
    Stops the running Mongoose HTTP server. Sets a flag to stop the background event loop task, and then frees the Mongoose associated resources.
    Arguments
    - `server::Server`: The server object to shutdown.
"""
function shutdown!(server::Server)
    if !server.running
        @info "Server not running. Nothing to do."
        return
    end
    @info "Stopping server..."
    server.running = false
    stop_workers!(server)
    stop_master!(server)
    free_resources!(server)
    unregister!(server)
    @info "Server stopped successfully."
    return
end

end
