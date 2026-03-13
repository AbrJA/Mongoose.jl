function build_request(conn::MgConnection, ev_data::Ptr{Cvoid})
    id = Int(conn)
    message = MgHttpMessage(ev_data)
    payload = HttpRequest(message)
    return IdRequest(id, payload)
end
