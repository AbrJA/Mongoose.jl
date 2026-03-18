"""
    AsyncServer — multi-threaded asynchronous server with worker pool.
    Uses separate channels for HTTP and WebSocket messages for full type stability.
"""

"""
    AsyncServer{R} — An asynchronous HTTP/WebSocket server with background worker threads.
    Separates event handling (main thread) from request processing (worker threads)
    via typed channels for maximum type stability and trim-safe compilation.

# Thread-Safety Invariant
The `connections` and `ws_connections` dicts are ONLY accessed from the event-loop thread.
Do NOT access them from worker threads or external code. This single-thread access pattern
is safe without locks and avoids contention.
"""
mutable struct AsyncServer{R <: Route} <: Server
    core::ServerCore{R}
    workers::Vector{Task}
    http_requests::Channel{IdRequest}
    ws_requests::Channel{IdWsMessage}
    http_responses::Channel{IdResponse}
    ws_responses::Channel{IdWsMessage}
    connections::Dict{Int,MgConnection}
    nworkers::Int
    nqueue::Int

    function AsyncServer(; timeout::Integer=0, nworkers::Integer=1, nqueue::Integer=1024, max_body_size::Integer=DEFAULT_MAX_BODY_SIZE, drain_timeout_ms::Integer=DEFAULT_DRAIN_TIMEOUT_MS)
        router = Router()
        server = new{typeof(router)}(
            ServerCore(timeout, router; max_body_size=max_body_size, drain_timeout_ms=drain_timeout_ms),
            Task[],
            Channel{IdRequest}(nqueue),
            Channel{IdWsMessage}(nqueue),
            Channel{IdResponse}(nqueue),
            Channel{IdWsMessage}(nqueue),
            Dict{Int,MgConnection}(),
            nworkers,
            nqueue
        )
        finalizer(free_resources!, server)
        return server
    end
end

"""
    setup_resources!(server::AsyncServer) — Initialize channels, connection map, and C handler.
"""
function setup_resources!(server::AsyncServer)
    server.core.manager = Manager()
    server.core.handler = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    server.http_requests = Channel{IdRequest}(server.nqueue)
    server.ws_requests = Channel{IdWsMessage}(server.nqueue)
    server.http_responses = Channel{IdResponse}(server.nqueue)
    server.ws_responses = Channel{IdWsMessage}(server.nqueue)
    server.connections = Dict{Int,MgConnection}()
    return
end

"""
    worker_loop(server, worker_index, router) — Worker thread main loop.
    Polls HTTP and WS request channels, processes requests, and writes responses.
"""
function worker_loop(server::AsyncServer, worker_index::Integer, router::Route)
    @info "Worker thread $worker_index started on thread $(Threads.threadid())"
    while server.core.running[]
        try
            # Try HTTP requests first, then WS
            if isready(server.http_requests)
                request = take!(server.http_requests)
                response = execute_http_handler(server, request)
                put!(server.http_responses, response)
            elseif isready(server.ws_requests)
                request = take!(server.ws_requests)
                response = handle_ws_message!(server, request)
                if response !== nothing
                    put!(server.ws_responses, response)
                end
            else
                # Nothing ready — brief sleep to avoid busy-spinning
                sleep(0.001)
            end
        catch e
            if !server.core.running[]
                break
            else
                @error "Worker thread error: $e" exception=(e, catch_backtrace())
            end
        end
    end
    @info "Worker thread $worker_index finished"
    return
end

"""
    start_workers!(server::AsyncServer) — Spawn worker tasks on Julia threads.
"""
function start_workers!(server::AsyncServer)
    resize!(server.workers, server.nworkers)
    for i in eachindex(server.workers)
        server.workers[i] = Threads.@spawn worker_loop(server, i, server.core.router)
    end
    return
end

"""
    stop_workers!(server::AsyncServer) — Close channels and wait for all workers to finish.
"""
function stop_workers!(server::AsyncServer)
    close(server.http_requests)
    close(server.ws_requests)
    for worker in server.workers
        try
            wait(worker)
        catch e
            # Ignore — worker may already be done
        end
    end
    return
end

"""
    process_responses!(server::AsyncServer) — Drain response channels and send to C connections.

This runs on the event-loop thread and dispatches responses back to clients.
"""
function process_responses!(server::AsyncServer)
    # Process HTTP responses
    while isready(server.http_responses)
        response = take!(server.http_responses)
        
        conn = get(server.connections, response.id, nothing)
        conn === nothing && continue
        
        if response.payload isa PreRenderedResponse
            mg_send(conn, response.payload.bytes)
        else
            mg_http_reply(conn, response.payload.status, response.payload.headers, response.payload.body)
        end
        # NOTE: Don't delete from connections here — keep-alive connections
        # may send multiple requests. Only clean up on MG_EV_CLOSE.
    end
    
    # Process WebSocket responses
    while isready(server.ws_responses)
        response = take!(server.ws_responses)
        
        conn = get(server.connections, response.id, nothing)
        conn === nothing && continue
        
        if response.payload isa WsTextMessage
            mg_ws_send(conn, response.payload.data, WS_OP_TEXT)
        elseif response.payload isa WsBinaryMessage
            mg_ws_send(conn, response.payload.data, WS_OP_BINARY)
        end
    end
    return
end

"""
    run_event_loop(server::AsyncServer) — Main poll loop for async server.
"""
function run_event_loop(server::AsyncServer)
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.timeout)
        process_responses!(server)
        
        if server.core.timeout == 0
            yield()
        end
    end
    return
end

"""
    cleanup_connection!(server::AsyncServer, conn) — Remove connection from tracking.
"""
function cleanup_connection!(server::AsyncServer, conn::MgConnection)
    delete!(server.connections, Int(conn))
    return
end

# --- HTTP Event Handlers for AsyncServer ---

"""
    handle_event!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn, ev_data)

Handle an incoming HTTP message — builds request and enqueues for worker processing.
Stores the connection mapping for response delivery.
"""
function handle_event!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    check_ws_upgrade(server, conn, ev_data) && return

    request = build_request(conn, ev_data)
    
    server.connections[request.id] = conn
    put!(server.http_requests, request)
    return
end

"""
    handle_event!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn, ev_data)

Handle connection close — clean up both WS and HTTP connection tracking.
"""
function handle_event!(server::AsyncServer, ::Val{MG_EV_CLOSE}, conn::MgConnection, ev_data::Ptr{Cvoid})
    cleanup_ws_connection!(server, conn)
    cleanup_connection!(server, conn)
    return
end
