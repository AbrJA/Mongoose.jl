module Mongoose

@info "Mongoose.jl version 0.2.0 has syntax changes. Review the documentation."

using Mongoose_jll

export AsyncServer, SyncServer, Request, Response, start!, shutdown!, shutdown_all!, route!, to_struct, to_string

include("wrappers.jl")
include("structs.jl")
include("routes.jl")
include("events.jl")
include("servers.jl")
include("registry.jl")

const VALID_METHODS = Set([:get, :post, :put, :patch, :delete])

"""
    route!(server::Server, method::Symbol, path::String, handler::Function)
    Registers an HTTP request handler for a specific method and URI.
    # Arguments
    - `server::Server`: The server to register the handler with.
    - `method::Symbol`: The HTTP method (e.g., :get, :post, :put, :patch, :delete).
    - `path::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
    - `handler::Function`: The Julia function to be called when a matching request arrives.
    This function should accept a `Request` object as its first argument, followed by any additional keyword arguments.
"""
function route!(server::Server, method::Symbol, path::AbstractString, handler::Function)
    if method ∉ VALID_METHODS
        error("Invalid HTTP method: $method")
    end
    if !occursin(':', path)
        if !haskey(server.router.fixed, path)
            server.router.fixed[path] = Fixed()
        end
        server.router.fixed[path].handlers[method] = handler
        return server
    end
    segments = eachsplit(path, '/'; keepempty=false)
    node = server.router.node
    for seg in segments
        if startswith(seg, ':')
            param = seg[2:end]
            # Create or validate dynamic child
            if (dyn = node.dynamic) === nothing
                dyn = Node()
                dyn.param = param
                node.dynamic = dyn
            elseif dyn.param != param
                error("Parameter conflict: :$param vs existing :$(dyn.param)")
            end
            node = dyn
        else
            # Static segment
            if (child = get(node.static, seg, nothing)) === nothing
                child = Node()
                node.static[seg] = child
            end
            node = child
        end
    end
    # Attach handler at final node
    node.handlers[method] = handler
    return server
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
