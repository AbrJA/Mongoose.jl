"""
    HTTP handler — translates Mongoose C events into high-level Request/Response.
"""

# --- SyncServer: direct dispatch on event-loop thread ---

function handle_event!(server::SyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    if check_ws_upgrade(server, conn, ev_data)
        return
    end

    message = MgHttpMessage(ev_data)

    # Body size limit check
    if message.body.len > server.core.max_body_size
        _send!(conn, Response(413, ContentType.text, "413 Payload Too Large"))
        return
    end

    req = ViewRequest(message)
    res = try
        _dispatch_http(server, req)
    catch e
        @error "Handler error" exception=(e, catch_backtrace())
        Response(500, ContentType.text, "500 Internal Server Error")
    end
    _send!(conn, res)
    return
end

# --- AsyncServer: queue to worker channels ---

function handle_event!(server::AsyncServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    if check_ws_upgrade(server, conn, ev_data)
        return
    end

    message = MgHttpMessage(ev_data)

    # Body size limit check
    if message.body.len > server.core.max_body_size
        _send!(conn, Response(413, ContentType.text, "413 Payload Too Large"))
        return
    end

    id = Int(conn)
    server.connections[id] = conn
    isopen(server.http_requests) && put!(server.http_requests, Tagged(id, Request(message)))
    return
end

# --- Dispatch pipeline (used by both sync handler and async workers) ---

"""
    _dispatch_http(server, request) → Response
"""
function _dispatch_http(server::AbstractServer, req::AbstractRequest)::AbstractResponse
    final = (r, args...) -> _dispatch_to_router(server.core.router, r)
    if isempty(server.core.middlewares)
        return final(req)
    end
    return execute_middleware(server.core.middlewares, req, Any[], final)
end

# Trim-safe specialization: StaticRouter dispatches directly, bypassing
# the middleware pipeline which uses abstract Function types and closures
# that cannot be resolved by --trim=safe.
@inline function _dispatch_http(server::SyncServer{<:StaticRouter}, req::AbstractRequest)::AbstractResponse
    return static_dispatch(server.core.router, req)
end

@inline function _dispatch_to_router(router::Router, req)
    matched = match_route(router, req.method, req.uri)
    if matched !== nothing
        handler = _get_handler(matched.handlers, req.method)
        if handler !== nothing
            return handler(req, matched.params...)
        end
        # Auto HEAD: use GET handler, return headers only
        if req.method === :head
            get_h = matched.handlers.get
            if get_h !== nothing
                resp = get_h(req, matched.params...)
                return Response(resp.status, resp.headers, "")
            end
        end
        return Response(405, ContentType.text, "405 Method Not Allowed")
    end
    return Response(404, ContentType.text, "404 Not Found")
end

@inline function _dispatch_to_router(router::StaticRouter, req)
    return static_dispatch(router, req)
end

# --- Response serialization ---

"""
    _send!(conn, response)
"""
function _send!(conn::MgConnection, res::Response)
    mg_http_reply(conn, res.status, res.headers, res.body)
end

function _send!(conn::MgConnection, res::BinaryResponse)
    mg_send(conn, res.bytes)
end
