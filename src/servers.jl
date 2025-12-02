# Server
mutable struct Manager
    ptr::Ptr{Cvoid}
    function Manager(; empty::Bool=false)
        empty && return new(C_NULL)
        ptr = Libc.malloc(Csize_t(128))
        ptr == C_NULL && error("Failed to allocate manager memory")
        mg_mgr_init!(ptr)
        return new(ptr)
    end
end

function cleanup!(manager::Manager)
    if manager.ptr != C_NULL
        mg_mgr_free!(manager.ptr)
        manager.ptr = C_NULL
    end
    return
end

# This in another file!

abstract type Server end

mutable struct SyncServer <: Server
    manager::Manager
    handler::Ptr{Cvoid}
    timeout::Cint
    master::Union{Nothing,Task}
    router::Router
    running::Bool

    function SyncServer(; timeout::Integer=0)
        mg_log_set_level(Cint(0))
        server = new(Manager(empty=true), C_NULL, Cint(timeout), nothing, Router(), false)
        finalizer(free_resources!, server)
        return server
    end
end

mutable struct AsyncServer <: Server
    manager::Manager
    handler::Ptr{Cvoid}
    timeout::Cint
    master::Union{Nothing,Task}
    workers::Vector{Task}
    requests::Channel{IdRequest}
    responses::Channel{IdResponse}
    connections::Dict{Int,MgConnection}
    router::Router
    nworkers::Int
    nqueue::Int
    running::Bool

    function AsyncServer(; timeout::Integer=0, nworkers::Integer=1, nqueue::Integer=1024)
        mg_log_set_level(Cint(0))
        server = new(Manager(empty=true), C_NULL, Cint(timeout), nothing, Task[],
            Channel{IdRequest}(nqueue), Channel{IdResponse}(nqueue), Dict{Int,MgConnection}(),
            Router(), nworkers, nqueue, false)
        finalizer(free_resources!, server)
        return server
    end
end

function free_resources!(server::Server)
    cleanup!(server.manager)
    server.handler = C_NULL
    # ccall(:malloc_trim, Cvoid, (Cint,), 0)
    return
end

function setup_listener!(server::Server, host::AbstractString, port::Integer)
    url = "http://$host:$port"
    fn_data = Ptr{Cvoid}(objectid(server))
    is_listen = mg_http_listen(server.manager.ptr, url, server.handler, fn_data)
    is_listen == C_NULL && error("Failed to start server on $url. Port may be in use.")
    @info "Listening on $url"
    return
end

function start_master!(server::Server)
    server.master = @async begin
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

function run_event_loop(server::AsyncServer)
    while server.running
        mg_mgr_poll(server.manager.ptr, server.timeout)
        process_responses!(server)
        yield()
    end
    return
end

function run_event_loop(server::SyncServer)
    while server.running
        mg_mgr_poll(server.manager.ptr, server.timeout)
        yield()
    end
    return
end

function process_responses!(server::AsyncServer)
    while isready(server.responses)
        response = take!(server.responses)
        conn = get(server.connections, response.id, nothing)
        conn === nothing && continue
        mg_http_reply(conn, response.payload.status, to_string(response.payload.headers), response.payload.body)
        delete!(server.connections, response.id)
    end
    return
end

function worker_loop(server::AsyncServer, worker_index::Int, router::Router)
    @info "Worker thread $worker_index started on thread $(Threads.threadid())"
    while server.running
        try
            request = take!(server.requests)
            response = match_route(router, request)
            put!(server.responses, response)
        catch e
            if !server.running
                break # Normal exit for shutdown
            else
                @error "Worker thread error: $e" exception = (e, catch_backtrace())
            end
        end
    end
    @info "Worker thread $worker_index finished"
    return
end

function start_workers!(server::AsyncServer)
    resize!(server.workers, server.nworkers)
    for i in eachindex(server.workers)
        server.workers[i] = Threads.@spawn worker_loop(server, i, server.router)
    end
    return
end

function start_workers!(::SyncServer)
    return
end

function handle_request(conn::MgConnection, server::SyncServer, request::IdRequest)
    response = match_route(server.router, request)
    mg_http_reply(conn, response.payload.status, to_string(response.payload.headers), response.payload.body)
    return
end

function setup_resources!(server::SyncServer)
    server.manager = Manager()
    server.handler = @cfunction(sync_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    return
end

function handle_request(conn::MgConnection, server::AsyncServer, request::IdRequest)
    server.connections[request.id] = conn
    put!(server.requests, request)
    return
end

function cleanup_connection(conn::MgConnection, server::AsyncServer)
    delete!(server.connections, Int(conn))
    return
end

function setup_resources!(server::AsyncServer)
    server.manager = Manager()
    server.handler = @cfunction(async_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    server.requests = Channel{IdRequest}(server.nqueue)
    server.responses = Channel{IdResponse}(server.nqueue)
    server.connections = Dict{Int,MgConnection}()
    return
end

function run_blocking!(server::Server)
    try
        wait(server.master)
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
    if !isnothing(server.master)
        wait(server.master)
        server.master = nothing
    end
    return
end

function stop_workers!(server::AsyncServer)
    close(server.requests)
    for worker in server.workers
        wait(worker)
    end
    return
end

function stop_workers!(::SyncServer)
    return
end
