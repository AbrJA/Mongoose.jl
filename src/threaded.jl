using Base.Threads
using ConcurrentCollections

mutable struct MgThreadPoolServer
   manager::Ptr{Cvoid}
   listener::Ptr{Cvoid}
   master::Union{Nothing, Task}
   workers::Vector{Task}
   requests::DualLinkedQueue{MgRequest}
   connections::ConcurrentDict{Int, MgConnection}
   counter::Atomic{Int}
   num_workers::Int
   running::Bool
end

const MG_THREAD_POOL_SERVER = Ref{MgThreadPoolServer}()

function mg_global_thread_pool_server(num_workers::Int)::MgThreadPoolServer
   if !isassigned(MG_THREAD_POOL_SERVER)
       MG_THREAD_POOL_SERVER[] = MgThreadPoolServer(C_NULL, C_NULL, nothing, Vector{Task}(), DualLinkedQueue{MgRequest}(), ConcurrentDict{Int, MgConnection}(), Atomic{Int}(0), num_workers, false)
   end
   return MG_THREAD_POOL_SERVER[]
end

function mg_threaded_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid}, fn_data::Ptr{Cvoid})
   if ev !== MG_EV_HTTP_MSG
       return
   end
   # @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data, FnData: $fn_data on thread $(Threads.threadid())"
   server = mg_global_thread_pool_server(Threads.nthreads())
   message = mg_http_message(ev_data)
   # @info "Request to $(mg_uri(message))"
   id = atomic_add!(server.counter, 1)
   server.connections[id] = conn
   request = mg_request(id, message)
   # @info "Received request: $(request.id)"
   try
       # @info "Queueing request: $(request.id) for processing"
       push!(server.requests, request)
   catch e
       @error "Failed to queue request: $e"
       mg_text_reply(conn, 500, "Internal Server Error")
       modify!(Returns(nothing), server.connections, id)
   end
   return
end

function start_worker_threads!(server::MgThreadPoolServer)
   router = mg_global_router()
   resize!(server.workers, server.num_workers)

   for i in eachindex(server.workers)
       server.workers[i] = @spawn begin
           @info "Worker thread $i started on thread $(Threads.threadid())"
           while server.running
               try
                   # @info "Worker $i waiting for request..."
                   request = popfirst!(server.requests)
                   # @info "Worker thread $i received request $(request.id)"
                   conn = server.connections[request.id]
                   if request.id == -1
                       @info "Worker thread $i received shutdown signal"
                       break
                   end
                   uri = request.uri
                   # @info "Worker thread $i processing request $uri $(uri == "")"
                   route = get(router.static, uri, nothing)
                   if !isnothing(route)
                       method = Symbol(request.method)
                       response = mg_route_handler(conn, method, route; message = request.message)
                       modify!(Returns(nothing), server.connections, request.id)
                       continue
                   end
                   for (regex, route) in router.dynamic
                       matched = match(regex, uri)
                       if !isnothing(matched)
                           method = Symbol(request.method)
                           response = mg_route_handler(conn, method, route; message = message, params = matched)
                           modify!(Returns(nothing), server.connections, request.id)
                           continue
                       end
                   end
                   @warn "404 Not Found: $uri"
                   response = mg_text_reply(conn, 404, "404 Not Found")
                   modify!(Returns(nothing), server.connections, request.id)
                   continue
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
   server.manager = ptr_mgr
   # Start worker threads
   start_worker_threads!(server)
   # Create event handler with server reference
   ptr_mg_event_handler = @cfunction(mg_threaded_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
   url = "http://$host:$port"
   listener = mg_http_listen(server.manager, url, ptr_mg_event_handler, C_NULL)
   if listener == C_NULL
       Libc.free(ptr_mgr)
       error("Failed to start threaded server on $url")
   end
   server.listener = listener
   server.running = true
   # Main event loop (still single-threaded for Mongoose)
   server.master = @async begin
       try
           @info "Main event loop started on thread $(Threads.threadid())"
           while server.running
               mg_mgr_poll(server.manager, 1)
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
       wait(server.master)
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
   for i in eachindex(server.workers)
       push!(server.requests, MgRequest(-1, C_NULL))
   end
   # Wait for workers to finish
   for task in server.workers
       wait(task)
   end
   # Wait for main task
   if !isnothing(server.master)
       wait(server.master)
   end
   # Clean up Mongoose resources
   if server.manager != C_NULL
       mg_mgr_free!(server.manager)
       Libc.free(server.manager)
       server.manager = C_NULL
   end
   @info "Threaded server shut down"
   return
end



# function worker_loop!(server::MgThreadPoolServer, worker_index::Int, router)
#     # router is passed in to avoid repeated access to mg_global_router()

#     @info "Worker thread $worker_index started on thread $(Threads.threadid())"

#     while server.running
#         try
#             # 1. Wait for and get a request
#             request = popfirst!(server.requests)
#             conn = server.connections[request.id]

#             # Check for sentinel value to signal shutdown
#             if request.id == -1
#                 break
#             end

#             # 2. Process the request (handle the routing)
#             handle_request!(server, conn, request, router)

#         catch e
#             if !server.running
#                 break # Normal exit for shutdown
#             else
#                 @error "Worker thread error: $e" exception=(e, catch_backtrace())
#                 # Optionally, re-queue the connection/request if it's recoverable,
#                 # but typically a thread-level error suggests a deeper issue.
#             end
#         end
#     end
#     # @info "Worker thread $worker_index finished"
#     return
# end


# function handle_request!(server::MgThreadPoolServer, conn, request, router)
#     uri = request.uri
#     message = request.message

#     # 1. Static Route Check
#     route = get(router.static, uri, nothing)
#     if !isnothing(route)
#         method = Symbol(mg_method(message))
#         # The routing function (mg_route_handler) should be called here
#         mg_route_handler(conn, method, route; message = message)

#         # Cleanup connection state regardless of outcome
#         modify!(Returns(nothing), server.connections, request.id)
#         return
#     end

#     # 2. Dynamic Route Check
#     for (regex, route) in router.dynamic
#         matched = match(regex, uri)
#         if !isnothing(matched)
#             method = Symbol(mg_method(message))
#             # Pass matched parameters to the handler
#             mg_route_handler(conn, method, route; message = message, params = matched)

#             # Cleanup connection state
#             modify!(Returns(nothing), server.connections, request.id)
#             return
#         end
#     end

#     # 3. 404 Not Found
#     @warn "404 Not Found: $uri"
#     mg_text_reply(conn, 404, "404 Not Found")

#     # Cleanup connection state
#     modify!(Returns(nothing), server.connections, request.id)
#     return
# end


# function start_worker_threads!(server::MgThreadPoolServer)
#     # 1. Setup
#     router = mg_global_router()
#     resize!(server.workers, server.num_workers)

#     # 2. Spawning Workers
#     for i in eachindex(server.workers)
#         # Pass the worker_loop function to @spawn with its necessary arguments
#         server.workers[i] = @spawn worker_loop!(server, i, router)
#     end

#     # Return value remains simple, indicating setup is complete
#     return
# end
