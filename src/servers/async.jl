mutable struct AsyncServer <: Server
    core::ServerCore
    workers::Vector{Task}
    requests::Channel{IdRequest}
    responses::Channel{IdResponse}
    connections::Dict{Int,MgConnection}
    connections_lock::ReentrantLock
    nworkers::Int
    nqueue::Int

    function AsyncServer(; timeout::Integer=0, nworkers::Integer=1, nqueue::Integer=1024)
        server = new(
            ServerCore(timeout, Router()),
            Task[],
            Channel{IdRequest}(nqueue),
            Channel{IdResponse}(nqueue),
            Dict{Int,MgConnection}(),
            ReentrantLock(),
            nworkers,
            nqueue
        )
        finalizer(free_resources!, server)
        return server
    end
end

function setup_resources!(server::AsyncServer)
    server.core.manager = Manager()
    server.core.handler = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    server.requests = Channel{IdRequest}(server.nqueue)
    server.responses = Channel{IdResponse}(server.nqueue)
    server.connections = Dict{Int,MgConnection}()
    return
end

function worker_loop(server::AsyncServer, worker_index::Integer, router::Route)
    @info "Worker thread $worker_index started on thread $(Threads.threadid())"
    while server.core.running[]
        try
            request = take!(server.requests)
            response = execute_http_handler(server, request)
            put!(server.responses, response)
        catch e
            if !server.core.running[]
                break # Normal exit
            else
                @error "Worker thread error: $e" exception=(e, catch_backtrace())
            end
        end
    end
    @info "Worker thread $worker_index finished"
    return
end

function start_workers!(server::AsyncServer)
    resize!(server.workers, server.nworkers)
    for i in eachindex(server.workers)
        server.workers[i] = Threads.@spawn worker_loop(server, i, server.core.router)
    end
    return
end

function stop_workers!(server::AsyncServer)
    close(server.requests)
    for worker in server.workers
        try
            wait(worker)
        catch e
            # Ignore
        end
    end
    return
end

function process_responses!(server::AsyncServer)
    while isready(server.responses)
        response = take!(server.responses)
        
        conn = lock(server.connections_lock) do
            get(server.connections, response.id, nothing)
        end
        conn === nothing && continue
        
        mg_http_reply(conn, response.payload.status, response.payload.headers, response.payload.body)
        
        lock(server.connections_lock) do
            delete!(server.connections, response.id)
        end
    end
    return
end

function run_event_loop(server::AsyncServer)
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        process_responses!(server)
        
        # If timeout is 0, yield to not hog the CPU
        if server.core.timeout == 0
            yield()
        end
    end
    return
end

function cleanup_connection!(server::AsyncServer, conn::MgConnection)
    lock(server.connections_lock) do
        delete!(server.connections, Int(conn))
    end
    return
end

# --- HTTP Event Handlers for AsyncServer ---

function handle_event!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    request = build_request(conn, ev_data)
    
    lock(server.connections_lock) do
        server.connections[request.id] = conn
    end
    put!(server.requests, request)
    return
end

function handle_event!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_connection!(server, conn)
    return
end
