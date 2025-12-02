# Maybe another name and add handle_request functions
function build_request(conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid})
    id = Int(conn)
    message = MgHttpMessage(ev_data)
    payload = Request(message)
    return IdRequest(id, payload)
end

function select_server(conn::Ptr{Cvoid})
    fn_data = mg_conn_get_fn_data(conn)
    id = UInt(fn_data)
    return REGISTRY[id]
end

function sync_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    # ev != MG_EV_POLL && @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data"
    ev == MG_EV_HTTP_MSG || return
    server = select_server(conn)
    request = build_request(conn, ev_data)
    handle_request(conn, server, request)
    return
end

function async_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    ev == MG_EV_POLL && return
    server = select_server(conn)
    ev == MG_EV_CLOSE && return cleanup_connection(conn, server)
    if ev == MG_EV_HTTP_MSG
        request = build_request(conn, ev_data)
        handle_request(conn, server, request)
    end
    return
end
