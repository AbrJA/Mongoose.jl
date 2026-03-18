mutable struct AsyncServer{R <: Route} <: Server
    core::ServerCore{R}
    workers::Vector{Task}
    requests::Channel{Union{IdRequest, IdWsMessage}}
    responses::Channel{Union{IdResponse, IdWsMessage}}
    connections::Dict{Int,MgConnection}
    nworkers::Int
    nqueue::Int

    function AsyncServer(; timeout::Integer=0, nworkers::Integer=1, nqueue::Integer=1024)
        router = Router()
        server = new{typeof(router)}(
            ServerCore(timeout, router),
            Task[],
            Channel{Union{IdRequest, IdWsMessage}}(nqueue),
            Channel{Union{IdResponse, IdWsMessage}}(nqueue),
            Dict{Int,MgConnection}(),
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
    server.requests = Channel{Union{IdRequest, IdWsMessage}}(server.nqueue)
    server.responses = Channel{Union{IdResponse, IdWsMessage}}(server.nqueue)
    server.connections = Dict{Int,MgConnection}()
    return
end

function worker_loop(server::AsyncServer, worker_index::Integer, router::Route)
    @info "Worker thread $worker_index started on thread $(Threads.threadid())"
    while server.core.running[]
        try
            request = take!(server.requests)
            if request isa IdRequest
                response = execute_http_handler(server, request)
                put!(server.responses, response)
            elseif request isa IdWsMessage
                response = handle_ws_message!(server, request)
                if response !== nothing
                    put!(server.responses, response)
                end
            end
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
        
        conn = get(server.connections, response.id, nothing)
        conn === nothing && continue
        
        if response isa IdResponse
            if response.payload isa PreRenderedResponse
                mg_send(conn, response.payload.bytes)
            else
                mg_http_reply(conn, response.payload.status, response.payload.headers, response.payload.body)
            end
            # Close HTTP connection after reply (unless keep-alive handled by Mongoose usually but we delete it so we don't leak)
            # Close HTTP connection after reply (unless keep-alive handled by Mongoose usually but we delete it so we don't leak)
            delete!(server.connections, response.id)
        elseif response isa IdWsMessage
            if response.payload.is_text
                mg_ws_send(conn, response.payload.data::String, Cint(1))
            else
                mg_ws_send(conn, response.payload.data::Vector{UInt8}, Cint(2))
            end
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
    delete!(server.connections, Int(conn))
    return
end

# --- HTTP Event Handlers for AsyncServer ---

function handle_event!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    check_ws_upgrade(server, conn, ev_data) && return

    request = build_request(conn, ev_data)
    
    server.connections[request.id] = conn
    put!(server.requests, request)
    return
end

function handle_event!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    cleanup_connection!(server, conn)
    return
end
