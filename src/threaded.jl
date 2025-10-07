using ConcurrentCollections

mutable struct MgThreadPoolServer
    mgr::Ptr{Cvoid}
    listener::Ptr{Cvoid}
    running::Bool
    main_task::Union{Task, Nothing}
    request_channel::DualLinkedQueue{MgRequest}
    response_channel::ConcurrentQueue{MgResponse}

    conn_map::Dict{Int, MgConnection}
    conn_id_counter::Atomic{Int}

    worker_tasks::Vector{Task}
    num_workers::Int
end

const MG_THREAD_POOL_SERVER = Ref{MgThreadPoolServer}()

function mg_global_thread_pool_server(num_workers::Int)::MgThreadPoolServer
    if !isassigned(MG_THREAD_POOL_SERVER)
        MG_THREAD_POOL_SERVER[] = MgThreadPoolServer(C_NULL, C_NULL, false, nothing, DualLinkedQueue{MgRequest}(), ConcurrentQueue{MgResponse}(), Dict{Int, MgConnection}(), Atomic{Int}(0), Vector{Task}(), num_workers)
    end
    return MG_THREAD_POOL_SERVER[]
end

function mg_threaded_route_handler(request::MgRequest, route::MgRoute; kwargs...)
    method = Symbol(request.method)
    if haskey(route.handlers, method)
            try
                return route.handlers[method](request; kwargs...)
            catch e # CHECK THIS TO ALWAYS RESPOND
                @error "Error handling request: $e" error = (e, catch_backtrace())
                return MgResponse(request.id, 500, Dict("Content-Type" => "text/plain"), "500 Internal Server Error")
            end
    else
        @warn "405 Method Not Allowed: $method"
        return MgResponse(request.id, 500, Dict("Content-Type" => "text/plain"), "500 Internal Server Error")
    end
end

function mg_threaded_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
    if ev !== MG_EV_HTTP_MSG
        return
    end
    # @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data, FnData: $fn_data on thread $(Threads.threadid())"
    server = mg_global_thread_pool_server(Threads.nthreads())
    message = mg_http_message(ev_data)
    conn_id = atomic_add!(server.conn_id_counter, 1)
    server.conn_map[conn_id] = conn
    # println("ptr method: ", message.method.ptr)
    # println("len method: ", message.method.len)
    # println("typeof ptr: ", typeof(message.method.ptr))
    # println("typeof len: ", typeof(message.method.len))
    request = mg_request(conn_id, message)
    # @info "Received request: $(request.id) from thread $(Threads.threadid())"
    try
        # @info "Queueing request: $(request.id) for processing on thread $(Threads.threadid())"
        push!(server.request_channel, request)
    catch e
        @error "Failed to queue request: $e"
        mg_text_reply(conn, 500, "Internal Server Error")
        delete!(server.conn_map, conn_id)
    end
    return
end

function start_worker_threads!(server::MgThreadPoolServer)
    router = mg_global_router()
    resize!(server.worker_tasks, server.num_workers)

    for i in 1:server.num_workers
        server.worker_tasks[i] = @spawn begin
            @info "Worker thread $i started on thread $(Threads.threadid())"

            # This is correct: popfirst! BLOCKS efficiently until a request is available.
            while server.running
                try
                    # @info "Worker $i waiting for request..."
                    request = popfirst!(server.request_channel)
                    if request.id == -1
                        break  # Shutdown signal received
                    end
                    uri = request.uri
                    # method = Symbol(request.method)
                    route = get(router.static, uri, nothing)
                    if !isnothing(route)
                        response = mg_threaded_route_handler(request, route)
                        push!(server.response_channel, response)
                        continue
                    end
                    for (regex, route) in router.dynamic
                        matched = match(regex, uri)
                        if !isnothing(matched)
                            response = mg_threaded_route_handler(request, route; params = matched)
                            push!(server.response_channel, response)
                            continue
                        end
                    end
                    response = MgResponse(request.id, 404, Dict("Content-Type" => "text/plain"), "404 Not Found")
                    @warn "404 Not Found: $uri"
                    push!(server.response_channel, response)
                    continue
                    # @info "Worker $i processing request: $(request.id) from thread $(Threads.threadid())"
                    # response = MgResponse(request.id, 200, Dict("Content-Type" => "application/json"), "{}")
                    # put!(server.response_channel, response)
                catch e
                    if !server.running
                        break # Normal exit for shutdown
                    else
                        @error "Worker thread error: $e"
                    end
                end
            end
            # @info "Worker thread $i finished"
        end
    end
    return
end

function mg_serve_threaded!(; host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true, num_workers::Int = Threads.nthreads())
    server = mg_global_thread_pool_server(num_workers)
    if server.running
        @warn "Threaded server already running."
        return
    end
    @info "Starting threaded server with $num_workers workers..."
    # Initialize Mongoose manager
    ptr_mgr = Libc.malloc(Csize_t(128))
    mg_mgr_init!(ptr_mgr)
    server.mgr = ptr_mgr
    # Start worker threads
    start_worker_threads!(server)
    # Create event handler with server reference
    ptr_mg_event_handler = @cfunction(mg_threaded_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    url = "http://$host:$port"
    listener = mg_http_listen(server.mgr, url, ptr_mg_event_handler, C_NULL)
    if listener == C_NULL
        Libc.free(ptr_mgr)
        close(server.request_channel)
        error("Failed to start threaded server on $url")
    end
    server.listener = listener
    server.running = true
    # Main event loop (still single-threaded for Mongoose)
    server.main_task = @async begin
        try
            @info "Main event loop started on thread $(Threads.threadid())"
            while server.running
                # Poll Mongoose for new events (CRITICAL: Must be done frequently)
                mg_mgr_poll(server.mgr, 1)

                # DRAIN RESPONSES NON-BLOCKINGLY
                while server.running
                    # Use maybepopfirst! to check for a completed response.
                    # This is NON-BLOCKING and returns immediately if empty.
                    maybe_response = maybepopfirst!(server.response_channel)

                    if maybe_response === nothing
                        # Queue is empty right now. Break the inner loop
                        # to quickly get back to mg_mgr_poll.
                        break
                    end

                    response = maybe_response.value # Unwrap the response from Some

                    # @info "Processing response from worker thread"
                    # @info "Processing response for connection ID $(response.id) with status $(response.status)"

                    conn = get(server.conn_map, response.id, nothing)
                    # @info "Connection for response: $(conn)"

                    if !isnothing(conn)
                        # The conn pointer is valid here, send the reply
                        mg_text_reply(conn, response.status, response.body)
                        # Clean up the map
                        delete!(server.conn_map, response.id)
                    else
                        # Note: Used response.id instead of response.conn for consistency
                        @warn "Connection ID $(response.id) not found, likely already closed."
                    end

                    # No yield() needed here; the break handles returning control.
                end

                # Yield is still useful here to be a good citizen on the main thread
                # before the next mg_mgr_poll, but is less critical now.
                yield()
            end
        catch e
            @error "Main loop error: $e" error = (e, catch_backtrace())
        finally
            @info "Main event loop finished"
        end
    end
    @info "Threaded server started on $url with $num_workers workers"
    if !async
        wait(server.main_task)
        mg_shutdown_threaded!()
    end

    return
end

function mg_shutdown_threaded!()::Nothing
    server = mg_global_thread_pool_server(Threads.nthreads())
    if !server.running
        return
    end

    @info "Shutting down threaded server..."
    server.running = false

    for i in 1:server.num_workers
        push!(server.request_channel, MgRequest(-1, "", "", "", "", Dict(), "", ""))
    end

    # Wait for workers to finish
    for task in server.worker_tasks
        wait(task)
    end

    # Wait for main task
    if !isnothing(server.main_task)
        wait(server.main_task)
    end

    # Clean up Mongoose resources
    if server.mgr != C_NULL
        mg_mgr_free!(server.mgr)
        Libc.free(server.mgr)
        server.mgr = C_NULL
    end
    @info "Threaded server shut down"
    return
end
