"""
    Core server structs and lifecycle primitives.
"""

"""
    Manager — RAII wrapper around the Mongoose C `mg_mgr` struct.
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
        Libc.free(manager.ptr)
        manager.ptr = C_NULL
    end
    return
end

"""
    ServerCore{R, A} — Shared state for all server types.
    Parameterized on:
    - `R`: Router type (for dynamic route! API)
    - `A`: App type (for static @routes dispatch, or NoApp for dynamic-only)

# Fields
- `app`: Static app instance for @routes dispatch (NoApp if using dynamic routing).
- `router`: The dynamic HTTP router (used when app is NoApp).
- `ws_router`: WebSocket router.
- `ws_connections`: Maps connection id → WS path (event-loop thread only).
- `middlewares`: Ordered middleware list.
- `max_body_size`: Max request body size in bytes.
- `drain_timeout_ms`: Shutdown drain timeout.
"""
mutable struct ServerCore{R <: AbstractRoute, A <: AbstractApp, W <: AbstractWsRoute}
    manager::Manager
    handler::Ptr{Cvoid}
    timeout::Cint
    master::Union{Nothing,Task}
    app::A
    router::R
    ws_router::W
    ws_connections::Dict{Int,String}
    running::Threads.Atomic{Bool}
    middlewares::Vector{Function}
    max_body_size::Int
    drain_timeout_ms::Int

    function ServerCore(timeout::Integer, router::R, app::A=NoApp(), ws_router::W=NoWsRouter(); max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS, c_handler::Ptr{Cvoid}=C_NULL) where {R <: AbstractRoute, A <: AbstractApp, W <: AbstractWsRoute}
        return new{R, A, W}(
            Manager(empty=true), c_handler, Cint(timeout), nothing,
            app, router, ws_router, Dict{Int,String}(),
            Threads.Atomic{Bool}(false), Function[],
            max_body_size, drain_timeout_ms
        )
    end
end

"""
    get_c_handler_async / get_c_handler_sync

Internal fallback functions to retrieve the generic or static AOT-compiled C-handler.
The `@routes` macro automatically overrides these for specific application types, returning a
strongly-typed `@cfunction` pointer suitable for `trim=safe` standalone compilation.
"""
get_c_handler_async(::Type{T}) where {T} = C_NULL
get_c_handler_sync(::Type{T}) where {T} = C_NULL

"""
    free_resources!(server) — Release all C resources held by the server.
"""
function free_resources!(server::AbstractServer)
    cleanup!(server.core.manager)
    server.core.handler = C_NULL
    return
end

"""
    setup_listener!(server, host, port) — Bind the server to the given host:port.

!!! note "GC Safety"
    `pointer_from_objref(server)` is passed to the C library as `fn_data`.
    The server MUST remain rooted (not garbage collected) for the lifetime of the listener.
    This is guaranteed because `register!(server)` stores the server in the global `REGISTRY`
    Dict before this function is called, and `unregister!` removes it only during `shutdown!`.
"""
function setup_listener!(server::AbstractServer, host::AbstractString, port::Integer)
    mg_log_set_level(Cint(0))
    url = "http://$host:$port"
    fn_data = pointer_from_objref(server)
    is_listen = mg_http_listen(server.core.manager.ptr, url, server.core.handler, fn_data)
    is_listen == C_NULL && throw(BindError("Failed to start server on $url. Port may be in use."))
    @info "Listening on $url"
    return
end

"""
    start_master!(server) — Spawn the event loop as a background task.
"""
function start_master!(server::AbstractServer)
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
function run_blocking!(server::AbstractServer)
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
function stop_master!(server::AbstractServer)
    if !isnothing(server.core.master)
        try
            wait(server.core.master)
        catch e
        end
        server.core.master = nothing
    end
    return
end
