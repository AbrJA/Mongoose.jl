"""
    Core server structs and lifecycle primitives.
"""

"""
    Manager — RAII wrapper around the Mongoose C `mg_mgr` struct.
    Manages memory lifecycle: allocation, initialization, and cleanup.
"""
mutable struct Manager
    ptr::Ptr{Cvoid}
    function Manager(; empty::Bool=false)
        empty && return new(C_NULL)
        ptr = Libc.calloc(1, Csize_t(MG_MGR_SIZE))
        ptr == C_NULL && throw(ServerError("Failed to allocate manager memory"))
        mg_mgr_init!(ptr)
        return new(ptr)
    end
end

"""
    cleanup!(manager) — Free the Mongoose manager and its allocated memory.
"""
function cleanup!(manager::Manager)
    if manager.ptr != C_NULL
        mg_mgr_free!(manager.ptr)
        # mg_mgr_free cleans up internal state but doesn't free the struct itself
        Libc.free(manager.ptr)
        manager.ptr = C_NULL
    end
    return
end

"""
    ServerCore{R} — Shared state for all server types.
    Parameterized on the router type `R` for type stability and trim-safe compilation.

# Fields
- `manager`: The Mongoose C manager.
- `handler`: C function pointer for the event callback.
- `timeout`: Poll timeout in milliseconds.
- `master`: The background task running the event loop.
- `router`: The HTTP router.
- `ws_router`: The WebSocket router.
- `ws_connections`: Maps connection pointer (as Int) → WS path.
    Only accessed from the event-loop thread (single-thread invariant).
- `running`: Atomic flag for thread-safe start/stop.
- `middlewares`: Ordered list of middleware to execute on each request.
- `max_body_size`: Maximum allowed request body size in bytes.
- `drain_timeout_ms`: Time to wait for in-flight requests during graceful shutdown.
"""
mutable struct ServerCore{R <: Route}
    manager::Manager
    handler::Ptr{Cvoid}
    timeout::Cint
    master::Union{Nothing,Task}
    router::R
    ws_router::WsRouter
    ws_connections::Dict{Int,String}
    running::Threads.Atomic{Bool}
    middlewares::Vector{Middleware}
    max_body_size::Int
    drain_timeout_ms::Int

    function ServerCore(timeout::Integer, router::R; max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS) where {R <: Route}
        return new{R}(
            Manager(empty=true), C_NULL, Cint(timeout), nothing,
            router, WsRouter(), Dict{Int,String}(),
            Threads.Atomic{Bool}(false), Middleware[],
            max_body_size, drain_timeout_ms
        )
    end
end

"""
    free_resources!(server) — Release all C resources held by the server.
"""
function free_resources!(server::Server)
    cleanup!(server.core.manager)
    server.core.handler = C_NULL
    return
end

"""
    setup_listener!(server, host, port) — Bind the server to the given host:port.
    Throws `BindError` if the port is already in use.
"""
function setup_listener!(server::Server, host::AbstractString, port::Integer)
    mg_log_set_level(Cint(0))
    url = "http://$host:$port"
    fn_data = Ptr{Cvoid}(objectid(server))
    is_listen = mg_http_listen(server.core.manager.ptr, url, server.core.handler, fn_data)
    is_listen == C_NULL && throw(BindError("Failed to start server on $url. Port may be in use."))
    @info "Listening on $url"
    return
end

"""
    start_master!(server) — Spawn the event loop as a background task on a Julia thread.
"""
function start_master!(server::Server)
    server.core.master = Threads.@spawn begin
        try
            @info "Server event loop task started on thread $(Threads.threadid())"
            run_event_loop(server)
        catch e
            if !isa(e, InterruptException)
                @error "Server event loop error: $e" exception = (e, catch_backtrace())
            end
        finally
            @info "Server event loop task finished."
        end
    end
    return
end

"""
    run_blocking!(server) — Wait for the event loop to finish (blocks the caller).
"""
function run_blocking!(server::Server)
    try
        wait(server.core.master)
    catch e
        if !isa(e, InterruptException)
            @error "Error while waiting for server" exception = (e, catch_backtrace())
        end
    finally
        shutdown!(server)
    end
    return
end

"""
    stop_master!(server) — Wait for the master event loop task to complete.
"""
function stop_master!(server::Server)
    if !isnothing(server.core.master)
        try
            wait(server.core.master)
        catch e
            # Ignore — task may already be done
        end
        server.core.master = nothing
    end
    return
end
