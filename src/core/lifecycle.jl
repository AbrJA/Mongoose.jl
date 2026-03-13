"""
    start!(server::Server; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=true)

    Starts the Mongoose HTTP server. Initialize the Mongoose manager, binds an HTTP listener, and starts a background Task to poll the Mongoose event loop.
"""
function start!(server::Server; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=true)
    # Use atomics for thread-safe state checking
    if Threads.atomic_xchg!(server.core.running, true)
        @info "Server already running. Nothing to do."
        return
    end
    
    @info "Starting server..."
    
    try
        register!(server)
        setup_resources!(server)
        setup_listener!(server, host, port)
        start_workers!(server)
        start_master!(server)
        
        blocking && run_blocking!(server)
    catch e
        # If startup fails, cleanly shutdown to free resources
        shutdown!(server)
        rethrow(e)
    end
    return
end

"""
    shutdown!(server::Server)
    Stops the running Mongoose HTTP server. Sets a flag to stop the background event loop task, and then frees the Mongoose associated resources.
"""
function shutdown!(server::Server)
    if !Threads.atomic_xchg!(server.core.running, false)
        @info "Server not running. Nothing to do."
        return
    end
    
    @info "Stopping server..."
    
    stop_workers!(server)
    stop_master!(server)
    free_resources!(server)
    unregister!(server)
    
    @info "Server stopped successfully."
    return
end
