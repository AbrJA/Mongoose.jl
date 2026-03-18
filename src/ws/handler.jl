function handle_ws_message!(server::Server, request::IdWsMessage)
    server.core.ws_router isa NoWsRouter && return nothing
    return _handle_dynamic_ws_message!(server, request)
end

function _handle_dynamic_ws_message!(server::Server, request::IdWsMessage)
    handlers = get_ws_handlers(server, request.id)
    if handlers !== nothing
        try
            res = handlers.on_message(request.payload)
            if res isa WsMessage
                return IdWsMessage(request.id, res)
            elseif res isa String
                return IdWsMessage(request.id, WsMessage(res, true))
            elseif res isa Vector{UInt8}
                return IdWsMessage(request.id, WsMessage(res, false))
            end
        catch e
            @error "WebSocket on_message error" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

function get_ws_handlers(server::Server, conn_id::Int)
    server.core.ws_router isa NoWsRouter && return nothing

    uri = lock(server.core.ws_lock) do
        get(server.core.ws_connections, conn_id, nothing)
    end
    if uri !== nothing
        return get(server.core.ws_router.routes, uri, nothing)
    end
    return nothing
end

"""
Helper function to intercept WebSocket upgrades during MG_EV_HTTP_MSG
"""
function check_ws_upgrade(server::Server, conn::MgConnection, ev_data::Ptr{Cvoid})
    server.core.ws_router isa NoWsRouter && return false
    return _check_dynamic_ws_upgrade(server, conn, ev_data)
end

function _check_dynamic_ws_upgrade(server::Server, conn::MgConnection, ev_data::Ptr{Cvoid})
    message = MgHttpMessage(ev_data)
    uri = to_string(message.uri)

    if haskey(server.core.ws_router.routes, uri)
        req = build_request(conn, ev_data)

        # Accept the upgrade
        mg_ws_upgrade(conn, ev_data, C_NULL)

        lock(server.core.ws_lock) do
            server.core.ws_connections[Int(conn)] = uri
        end

        handlers = server.core.ws_router.routes[uri]
        if handlers.on_open !== nothing
            try
                handlers.on_open(req.payload)
            catch e
                @error "WebSocket on_open error" exception = (e, catch_backtrace())
            end
        end
        return true
    end
    return false
end

function handle_event!(server::AsyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    lock(server.connections_lock) do
        server.connections[Int(conn)] = conn
    end
    msg = WsMessage(MgWsMessage(ev_data))
    req = IdWsMessage(Int(conn), msg)
    put!(server.requests, req)
    return
end

function handle_event!(server::SyncServer, ::Val{MG_EV_WS_MSG}, conn::MgConnection, ev_data::Ptr{Cvoid})
    msg = WsMessage(MgWsMessage(ev_data))
    req = IdWsMessage(Int(conn), msg)

    res = handle_ws_message!(server, req)
    if res isa IdWsMessage
        if res.payload.is_text
            mg_ws_send(conn, res.payload.data::String, Cint(1))
        else
            mg_ws_send(conn, res.payload.data::Vector{UInt8}, Cint(2))
        end
    end
    return
end

function handle_event!(server::Server, ::Val{MG_EV_WS_CTL}, conn::MgConnection, ev_data::Ptr{Cvoid})
    # Control frames (like ping/pong) are largely handled internally by mongoose
    # We could expose them, but usually they don't need user logic
    return
end

function cleanup_ws_connection!(server::Server, conn::MgConnection)
    server.core.ws_router isa NoWsRouter && return
    conn_id = Int(conn)
    handlers = get_ws_handlers(server, conn_id)

    if handlers !== nothing
        if handlers.on_close !== nothing
            try
                handlers.on_close()
            catch e
                @error "WebSocket on_close error" exception = (e, catch_backtrace())
            end
        end
        lock(server.core.ws_lock) do
            delete!(server.core.ws_connections, conn_id)
        end
    end
    return
end

"""
Helper function to send a message to a specific connection
"""
function send_ws(conn::MgConnection, message::String)
    # OPC_TEXT = 1
    mg_ws_send(conn, message, Cint(1))
end

function send_ws(conn::MgConnection, payload::Vector{UInt8})
    # OPC_BINARY = 2
    mg_ws_send(conn, payload, Cint(2))
end
