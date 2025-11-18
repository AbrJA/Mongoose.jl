module Mongoose

using Mongoose_jll

export Server, Request, Response, start!, stop!, register!

include("wrappers.jl")
include("structs.jl")
include("routes.jl")
include("constants.jl")

# --- 5. Event handling ---
function build_request(conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid})
    id = Int(conn)
    message = MgHttpMessage(ev_data)
    payload = Request(message)
    return IdRequest(id, payload)
end

function select_server(conn::Ptr{Cvoid})
    fn_data = mg_conn_get_fn_data(conn)
    id = Int(fn_data)
    return SERVER_REGISTRY[id]
end

function event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    # ev != MG_EV_POLL && @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data"
    ev == MG_EV_HTTP_MSG || return
    server = select_server(conn)
    request = build_request(conn, ev_data)
    response = resolve_request(server.router, request)
    return mg_http_reply(conn, response.payload.status, to_string(response.payload.headers), response.payload.body)
end

function threaded_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    # ev != MG_EV_POLL && @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data"
    ev == MG_EV_HTTP_MSG || return
    server = select_server(conn)
    request = build_request(conn, ev_data)
    put!(server.requests, request)
    return
end

function setup_listener!(server::Server, host::AbstractString, port::Integer)
    server.handler = @cfunction(event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    # MAYBE: Put this in the constructor
    url = "http://$host:$port"
    fn_data = register(server)
    listener = mg_http_listen(server.manager.ptr, url, server.handler, fn_data)
    if listener == C_NULL
        deregister(server)
        cleanup!(server)
        error("Failed to start server on $url (errno: $(Libc.errno()))")
    end
    server.listener = listener
    @info "Listening on $url"
    return
end

function start_event_loop!(server::Server)
    server.master = @async begin
        try
            @info "Starting server event loop task on thread $(Threads.threadid())"
            run_event_loop(server)
        catch e
            if !isa(e, InterruptException)
                @error "Server event loop error" exception = (e, catch_backtrace())
            end
        finally
            @info "Server event loop task finished."
        end
    end
    return
end

function run_event_loop(server::Server)
    while server.running
        mg_mgr_poll(server.manager.ptr, server.timeout)
        yield()
    end
    return
end

# function process_responses(server::Server)
#     while isready(server.responses)
#         response = take!(server.responses)
#         conn = server.connections[response.id]
#         mg_http_reply(conn, response.payload.status, to_string(response.payload.headers), response.payload.body)
#         delete!(server.connections, response.id)
#     end
#     return
# end

function wait_and_stop!(server::Server)
    try
        wait(server.master)
    catch e
        if !isa(e, InterruptException)
            @error "Error while waiting for server" exception = (e, catch_backtrace())
        end
    finally
        stop!(server)
    end
    return
end

# function worker_loop(server::Server, worker_index::Int, router::Router)
#     @info "Worker thread $worker_index started on thread $(Threads.threadid())"
#     while server.running
#         try
#             request = take!(server.requests)
#             response = resolve_request(request, router)
#             put!(server.responses, response)
#         catch e
#             if !server.running
#                 break # Normal exit for shutdown
#             else
#                 @error "Worker thread error: $e" exception=(e, catch_backtrace())
#             end
#         end
#     end
#     @info "Worker thread $worker_index finished"
#     return
# end

# function start_worker_threads!(server::Server)
#     resize!(server.workers, server.nworkers)
#     for i in eachindex(server.workers)
#         server.workers[i] = Threads.@spawn worker_loop(server, i, server.router)
#     end
#     return
# end

# --- 6. Server Management ---
"""
    start!(; server::Server = default_server(), host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true)

    Starts the Mongoose HTTP server. Initialize the Mongoose manager, binds an HTTP listener, and starts a background Task to poll the Mongoose event loop.

    Arguments
    - `server::Server = default_server()`: The server object to start. If not provided, the default server is used.
    - `host::AbstractString="127.0.0.1"`: The IP address or hostname to listen on. Defaults to "127.0.0.1" (localhost).
    - `port::Integer=8080`: The port number to listen on. Defaults to 8080.
    - `async::Bool=true`: If true, runs the server in a non-blocking mode. If false, blocks until the server is stopped.
"""
function start!(; server::Server = default_server(), host::AbstractString="127.0.0.1", port::Integer=8080, async::Bool = true)
    !server.running || (@warn "Server already running."; return)
    @info "Starting server..."
    server.manager = Manager()
    setup_listener!(server, host, port)
    server.running = true
    start_event_loop!(server)
    @info "Server started successfully."
    async || wait_and_stop!(server)
    return
end

"""
    stop!(; server::Server = default_server())
    Stops the running Mongoose HTTP server. Sets a flag to stop the background event loop task, and then frees the Mongoose associated resources.
    Arguments
    - `server::Server = default_server()`: The server object to shutdown. If not provided, the default server is used.
"""
function stop!(server::Server = default_server())
    if server.running
        @info "Stopping server..."
        server.running = false
        if !isnothing(server.master)
            wait(server.master)
            server.master = nothing
        end
        deregister(server)
        cleanup!(server)
        @info "Server stopped successfully."
    else
        @warn "Server not running."
    end
    return
end

end
