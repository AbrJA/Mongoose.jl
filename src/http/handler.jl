"""
    HTTP handler — translates Mongoose C events into high-level Request/Response.
"""

"""
    handle_event!(server::AbstractServer, ::Val{MG_EV_HTTP_MSG}, conn, ev_data)
"""
function handle_event!(server::AbstractServer, ::Val{MG_EV_HTTP_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    if check_ws_upgrade(server, conn, ev_data)
        return
    end

    message = MgHttpMessage(ev_data)
    req = build_request(server, conn, message)
    res = _dispatch_http(server, req)
    send_response!(conn, res)
    return
end

"""
    _dispatch_http(server, request) → Response
"""
function _dispatch_http(server::AbstractServer, req::AbstractRequest)::AbstractResponse
    if !isempty(server.core.middlewares)
        for mw in server.core.middlewares
            res = mw(req)
            res !== nothing && return res
        end
    end
    return _dispatch_to_router(server.core.http, req)
end

@inline function _dispatch_to_router(router::DynamicHttpRouter, req)
    matched = match_route(router, req.method, req.uri)
    if matched !== nothing
        return matched.handlers[req.method](req, matched.params...)
    end
    return Response(404, "Content-Type: text/plain\r\n", "404 Not Found")
end

@inline function _dispatch_to_router(router::StaticHttpRouter, req)
    res = static_dispatch(router, req)
    if res !== nothing
        return res
    end
    return Response(404, "Content-Type: text/plain\r\n", "404 Not Found")
end

"""
    build_request(server::AsyncServer, conn, msg) → Request
    build_request(server::SyncServer, conn, msg) → ViewRequest
"""
build_request(::AsyncServer, conn, msg) = Request(msg)
build_request(::SyncServer, conn, msg) = ViewRequest(msg)

"""
    send_response!(conn, response)
"""
function send_response!(conn::MgConnection, res::Response)
    mg_http_reply(conn, res.status, res.headers, res.body)
end

function send_response!(conn::MgConnection, res::PreRenderedResponse)
    mg_send(conn, res.bytes, length(res.bytes))
end
