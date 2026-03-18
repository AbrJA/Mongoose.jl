# Server Manager wrapper
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

function cleanup!(manager::Manager)
    if manager.ptr != C_NULL
        mg_mgr_free!(manager.ptr)
        # We allocated this ourselves, mg_mgr_free cleans up internal state
        # but we also need to free the memory we allocated. Actually mg_mgr_free 
        # doesn't free the struct itself, just its contents.
        Libc.free(manager.ptr)
        manager.ptr = C_NULL
    end
    return
end

# Core server state shared across all server types
mutable struct ServerCore{R <: Route}
    manager::Manager
    handler::Ptr{Cvoid}
    timeout::Cint
    master::Union{Nothing,Task}
    router::R # will be set to Router in http layer
    ws_router::WsRouter # WebSocket router
    ws_connections::Dict{Int,String} # Maps conn ID to WS path
    running::Threads.Atomic{Bool}
    middlewares::Vector{Middleware}

    function ServerCore(timeout::Integer, router::R) where {R <: Route}
        return new{R}(Manager(empty=true), C_NULL, Cint(timeout), nothing, router, WsRouter(), Dict{Int,String}(), Threads.Atomic{Bool}(false), Middleware[])
    end
end

function free_resources!(server::Server)
    cleanup!(server.core.manager)
    server.core.handler = C_NULL
    return
end

function setup_listener!(server::Server, host::AbstractString, port::Integer)
    mg_log_set_level(Cint(0))
    url = "http://$host:$port"
    fn_data = Ptr{Cvoid}(objectid(server))
    is_listen = mg_http_listen(server.core.manager.ptr, url, server.core.handler, fn_data)
    is_listen == C_NULL && throw(BindError("Failed to start server on $url. Port may be in use."))
    @info "Listening on $url"
    return
end

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

function stop_master!(server::Server)
    if !isnothing(server.core.master)
        try
            # Master might already be done or wait could hang, give it a moment
            # The event loop will exit when running becomes false
            wait(server.core.master)
        catch e
            # Ignore
        end
        server.core.master = nothing
    end
    return
end
