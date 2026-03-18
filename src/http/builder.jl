"""
    HTTP request builder — constructs typed request objects from C event data.
"""

"""
    build_request(conn, ev_data) → IdRequest{HttpRequest}

Build a fully-parsed, owned HTTP request from C connection and event data.
Used by `AsyncServer` where the request must survive beyond the event callback.
"""
function build_request(conn::MgConnection, ev_data::Ptr{Cvoid})
    id = Int(conn)
    message = MgHttpMessage(ev_data)
    payload = HttpRequest(message)
    return IdRequest(id, payload)
end

"""
    build_request(conn, message::MgHttpMessage) → IdRequest{HttpRequest}

Build from an already-parsed `MgHttpMessage` (avoids double parsing).
"""
function build_request(conn::MgConnection, message::MgHttpMessage)
    id = Int(conn)
    payload = HttpRequest(message)
    return IdRequest(id, payload)
end

"""
    build_view_request(conn, ev_data) → IdRequest{ViewRequest}

Build a lightweight view request from C connection and event data.
The `ViewRequest` contains zero-copy references to C memory and is only valid
during the current event callback. Used by `SyncServer`.
"""
function build_view_request(conn::MgConnection, ev_data::Ptr{Cvoid})
    id = Int(conn)
    message = MgHttpMessage(ev_data)
    payload = ViewRequest(message)
    return IdRequest(id, payload)
end
