"""
    Connection abstraction — hides raw C pointers behind a safe interface.
    All FFI writes to connections go through these functions.
"""

"""
    send_http_response!(conn, response)

Send a buffered HTTP response. Routes through `mg_http_reply` for string bodies
or raw `mg_send` for binary bodies.
"""
function send_http_response!(conn::MgConnection, res::Response)
    headers_str = format_headers(res.headers)
    if res.body isa Vector{UInt8}
        _send_binary_response!(conn, res.status, headers_str, res.body)
    else
        mg_http_reply(conn, res.status, headers_str, res.body)
    end
end

"""
    send_http_response!(conn, response, request_id)

Send response with X-Request-Id header injected.
"""
function send_http_response!(conn::MgConnection, res::Response, rid::String)
    headers_str = string(format_headers(res.headers), "X-Request-Id: ", rid, "\r\n")
    if res.body isa Vector{UInt8}
        _send_binary_response!(conn, res.status, headers_str, res.body)
    else
        mg_http_reply(conn, res.status, headers_str, res.body)
    end
end

"""
    send_ws_frame!(conn, data)

Send a WebSocket frame (text or binary, auto-detected).
"""
send_ws_frame!(conn::MgConnection, data::String) = mg_ws_send(conn, data, WS_OP_TEXT)
send_ws_frame!(conn::MgConnection, data::Vector{UInt8}) = mg_ws_send(conn, data, WS_OP_BINARY)
send_ws_frame!(conn::MgConnection, msg::Message) = send_ws_frame!(conn, msg.data)

# --- Internal binary response assembly ---

function _send_binary_response!(conn::MgConnection, res::Response)
    _send_binary_response!(conn, res.status, format_headers(res.headers), res.body::Vector{UInt8})
end

function _send_binary_response!(conn::MgConnection, status::Int, headers::String, body::Vector{UInt8})
    status_text = status_reason(status)
    head = string("HTTP/1.1 ", status, " ", status_text, "\r\n",
                  headers, "Content-Length: ", length(body), "\r\n",
                  "Connection: close\r\n\r\n")
    hlen = ncodeunits(head)
    buf = Vector{UInt8}(undef, hlen + length(body))
    copyto!(buf, 1, codeunits(head), 1, hlen)
    isempty(body) || copyto!(buf, hlen + 1, body, 1, length(body))
    mg_send(conn, buf)
end

# --- Streaming support ---

"""
    StreamWriter — IO interface for writing chunked data to a connection.

    Used by `StreamResponse` producers. Each `write` emits a chunk.
    Call `close` to send the terminal chunk and signal end-of-body.
"""
mutable struct StreamWriter <: IO
    conn::MgConnection
    open::Bool
end

function Base.write(w::StreamWriter, data::String)
    w.open || error("StreamWriter is closed")
    chunk = string(string(ncodeunits(data); base=16), "\r\n", data, "\r\n")
    buf = Vector{UInt8}(codeunits(chunk))
    mg_send(w.conn, buf)
    return ncodeunits(data)
end

function Base.write(w::StreamWriter, data::Vector{UInt8})
    w.open || error("StreamWriter is closed")
    header = string(string(length(data); base=16), "\r\n")
    hbuf = Vector{UInt8}(codeunits(header))
    trailer = Vector{UInt8}(codeunits("\r\n"))
    buf = Vector{UInt8}(undef, length(hbuf) + length(data) + 2)
    copyto!(buf, 1, hbuf, 1, length(hbuf))
    copyto!(buf, length(hbuf) + 1, data, 1, length(data))
    copyto!(buf, length(hbuf) + length(data) + 1, trailer, 1, 2)
    mg_send(w.conn, buf)
    return length(data)
end

function Base.flush(::StreamWriter)
    # No-op: mg_send buffers are flushed on next poll
    nothing
end

function Base.close(w::StreamWriter)
    if w.open
        mg_send(w.conn, Vector{UInt8}(codeunits("0\r\n\r\n")))
        w.open = false
    end
end

Base.isopen(w::StreamWriter) = w.open

"""
    send_stream_response!(conn, stream_resp)

Initiate a chunked streaming response. Sends headers immediately,
then calls the producer with a StreamWriter.
"""
function send_stream_response!(conn::MgConnection, resp::StreamResponse)
    headers = string(
        content_type_header_raw(resp.content_type),
        format_headers(resp.headers),
        "Transfer-Encoding: chunked\r\n"
    )
    head = string("HTTP/1.1 ", resp.status, " ", status_reason(resp.status), "\r\n",
                  headers, "\r\n")
    mg_send(conn, Vector{UInt8}(codeunits(head)))

    writer = StreamWriter(conn, true)
    try
        resp.producer(writer)
    finally
        close(writer)
    end
end

@inline content_type_header_raw(ct::String) = "Content-Type: " * ct * "\r\n"
