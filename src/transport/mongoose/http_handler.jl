"""
    HTTP event handler — the hot path from C event → Request → Response → send.

    The dispatch pipeline itself (`invoke_request`, `dispatch_to_handler`,
    `error_response`) lives in `MongooseCore`; this file binds it to the
    transport/server.
"""

# --- Request ID resolution ---

@inline function resolve_request_id(req::Request, server::AbstractServer)::String
    h = get(req.headers, "x-request-id", nothing)
    if h !== nothing
        safe = sanitize_header_value(h)
        !isempty(safe) && return safe
    end
    return string(Threads.atomic_add!(server.id_seq, UInt64(1)) + UInt64(1))
end

# --- Shared preprocessing ---

function preprocess_http(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})::Union{Nothing,Request}
    msg = MgHttpMessage(ev_data)
    method = parse_method(msg.method)
    uri = to_string(msg.uri)

    # 1. WebSocket upgrade check
    if has_ws_routes(server.router)
        endpoint = ws_endpoint(server.router, uri)
        if endpoint !== nothing
            ws_upgrade!(server, conn, ev_data, uri, endpoint, msg)
            return nothing
        end
    end

    # 2. Body size enforcement
    if msg.body.len > server.max_body
        send_http_response!(conn, error_response(server.errors, 413))
        return nothing
    end

    # 3. Static file serving (before handler dispatch)
    if serve_static!(server, conn, ev_data, method, uri)
        return nothing
    end

    # 4. Build Request from FFI data
    return adapt_request(msg, method, uri)
end

# --- Unified HTTP handler (sync and async branching on app.workers) ---

function on_http_message(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid})
    req = preprocess_http(server, conn, ev_data)
    req === nothing && return

    if server.workers == 0
        # Sync path: handle inline
        res = try
            invoke_http(server, req)
        catch e
            @log_error "Handler error uri=$(req.uri)" e catch_backtrace()
            error_response(server.errors, req, 500)
        end
        rid = resolve_request_id(req, server)
        if res isa StreamResponse
            send_stream_response!(conn, res)
        else
            send_http_response!(conn, res::Response, rid)
        end
    else
        # Async path: enqueue to worker pool
        id = Int(Threads.atomic_add!(server.conn_seq, UInt64(1)) + UInt64(1))
        server.connections[id] = conn

        tagged = Tagged{Union{Request,Intent}}(id, req)
        if !try_enqueue!(server.calls, tagged, server.queuesize)
            delete!(server.connections, id)
            send_http_response!(conn, error_response(server.errors, 503))
        end
    end
end

# --- HTTP dispatch (thin transport wrapper over the core pipeline) ---

function invoke_http(server::AbstractServer, req::Request)::Union{Response,StreamResponse}
    return invoke_request(
        server.router, server.middlewares, server.errors, server.services, req)
end

# --- Static File Serving ---

@inline function serve_static!(server::AbstractServer, conn::MgConnection, ev_data::Ptr{Cvoid},
                               method::Symbol, uri::String)::Bool
    isempty(server.mounts) && return false
    match_route_exact(server.router, method, uri) !== nothing && return false

    for (dir, prefix) in server.mounts
        static_file_exists(dir, prefix, uri) || continue
        root_dir = prefix == "/" ? dir : "$dir,$prefix=$dir"
        opts = Ref(MgHttpServeOpts(Base.unsafe_convert(Cstring, root_dir)))
        GC.@preserve root_dir begin
            mg_http_serve_dir(conn, ev_data, opts)
        end
        return true
    end
    return false
end

@inline function static_file_exists(root::String, prefix::String, uri::String)::Bool
    if prefix == "/"
        rel = uri
    elseif startswith(uri, prefix * "/") || uri == prefix
        rel = uri[length(prefix)+1:end]
    else
        return false
    end

    qi = findfirst('?', rel)
    qi !== nothing && (rel = rel[1:prevind(rel, qi)])
    rel = lstrip(rel, '/')

    candidate = normpath(joinpath(root, rel))
    (candidate == root || startswith(candidate, root * Base.Filesystem.path_separator)) || return false

    isfile(candidate) && return true
    isfile(candidate * ".gz") && return true
    isfile(joinpath(isempty(rel) ? root : candidate, "index.html")) && return true
    return false
end

# --- Routing convenience on server/app ---

function route!(server::AbstractServer, method::Symbol, path::AbstractString, @nospecialize(handler::Function);
                middleware::Vector{<:AbstractMiddleware}=AbstractMiddleware[],
                metadata=nothing)
    route!(server.router, method, path, handler; middleware=middleware, metadata=metadata)
    return server
end

function route!(server::AbstractServer, method::AbstractString, path::AbstractString, @nospecialize(handler::Function);
                middleware::Vector{<:AbstractMiddleware}=AbstractMiddleware[],
                metadata=nothing)
    route!(server.router, Symbol(lowercase(method)), path, handler;
           middleware=middleware, metadata=metadata)
    return server
end

function ws!(server::AbstractServer, path::AbstractString; kwargs...)
    ws!(server.router, path; kwargs...)
    return server
end

# Method-specific helpers for server/app (extend Base where applicable to avoid ambiguity)
Base.get!(server::AbstractServer, path::AbstractString, @nospecialize(h::Function)) = (route!(server, :get, path, h); server)
post!(server::AbstractServer, path::AbstractString, @nospecialize(h::Function)) = (route!(server, :post, path, h); server)
Base.put!(server::AbstractServer, path::AbstractString, @nospecialize(h::Function)) = (route!(server, :put, path, h); server)
patch!(server::AbstractServer, path::AbstractString, @nospecialize(h::Function)) = (route!(server, :patch, path, h); server)
Base.delete!(server::AbstractServer, path::AbstractString, @nospecialize(h::Function)) = (route!(server, :delete, path, h); server)
options!(server::AbstractServer, path::AbstractString, @nospecialize(h::Function)) = (route!(server, :options, path, h); server)
head!(server::AbstractServer, path::AbstractString, @nospecialize(h::Function)) = (route!(server, :head, path, h); server)

# Do-block convenience
Base.get!(f::Function, server::AbstractServer, path::AbstractString) = Base.get!(server, path, f)
post!(f::Function, server::AbstractServer, path::AbstractString) = post!(server, path, f)
Base.put!(f::Function, server::AbstractServer, path::AbstractString) = Base.put!(server, path, f)
patch!(f::Function, server::AbstractServer, path::AbstractString) = patch!(server, path, f)
Base.delete!(f::Function, server::AbstractServer, path::AbstractString) = Base.delete!(server, path, f)
options!(f::Function, server::AbstractServer, path::AbstractString) = options!(server, path, f)
head!(f::Function, server::AbstractServer, path::AbstractString) = head!(server, path, f)

"""
    serve!(server, directory; uri_prefix="/")

Serve static files from `directory`.
"""
function serve!(server::AbstractServer, directory::AbstractString; uri_prefix::AbstractString="/")
    dir = rstrip(abspath(directory), '/')
    isdir(dir) || throw(ArgumentError("serve!: directory does not exist: $dir"))
    prefix = "/" * lstrip(rstrip(uri_prefix, '/'), '/')
    push!(server.mounts, (dir, prefix))
    return server
end

"""
    serve!(server, uri_prefix, directory)

Positional 3-arg form: serve static files from `directory` under `uri_prefix`.
"""
function serve!(server::AbstractServer, uri_prefix::AbstractString, directory::AbstractString)
    dir = rstrip(abspath(directory), '/')
    isdir(dir) || throw(ArgumentError("serve!: directory does not exist: $dir"))
    prefix = "/" * lstrip(rstrip(uri_prefix, '/'), '/')
    push!(server.mounts, (dir, prefix))
    return server
end
