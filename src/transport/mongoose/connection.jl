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
                  headers, "Content-Length: ", length(body), "\r\n\r\n")
    hlen = ncodeunits(head)
    buf = Vector{UInt8}(undef, hlen + length(body))
    copyto!(buf, 1, codeunits(head), 1, hlen)
    isempty(body) || copyto!(buf, hlen + 1, body, 1, length(body))
    mg_send(conn, buf)
end

# --- Streaming support ---

# Chunked-encoding terminal chunk, enqueued once per stream.
const _STREAM_TERMINAL = UInt8[0x30, 0x0d, 0x0a, 0x0d, 0x0a]

"""
    StreamWriter — chunked-encoding writer fed by a task, drained by the loop.

    `write` enqueues a chunk onto the stream's channel; the event loop drains
    the channel and sends bytes with `mg_send` on the poll thread. Producers
    therefore never touch the connection directly, and a slow producer only
    blocks its own task (bounded channel = natural backpressure), never the
    event loop.

    `close`/EOF pushes the terminal chunk followed by a `nothing` sentinel.
"""
mutable struct StreamWriter <: IO
    channel::Channel{Union{Vector{UInt8},Nothing}}
    open::Bool
end

function Base.write(w::StreamWriter, data::String)
    w.open || error("StreamWriter is closed")
    chunk = string(string(ncodeunits(data); base=16), "\r\n", data, "\r\n")
    put!(w.channel, Vector{UInt8}(codeunits(chunk)))
    return ncodeunits(data)
end

function Base.write(w::StreamWriter, data::Vector{UInt8})
    w.open || error("StreamWriter is closed")
    header = string(string(length(data); base=16), "\r\n")
    hbuf = Vector{UInt8}(codeunits(header))
    trailer = UInt8[0x0d, 0x0a]
    buf = Vector{UInt8}(undef, length(hbuf) + length(data) + 2)
    copyto!(buf, 1, hbuf, 1, length(hbuf))
    copyto!(buf, length(hbuf) + 1, data, 1, length(data))
    copyto!(buf, length(hbuf) + length(data) + 1, trailer, 1, 2)
    put!(w.channel, buf)
    return length(data)
end

function Base.flush(::StreamWriter)
    # No-op: chunks are drained by the event loop on its next pass.
    nothing
end

function Base.close(w::StreamWriter)
    if w.open
        try
            put!(w.channel, _STREAM_TERMINAL)
            put!(w.channel, nothing)
        catch e
            e isa InvalidStateException || rethrow(e)
        end
        w.open = false
    end
end

Base.isopen(w::StreamWriter) = w.open

"""
    send_stream_response!(server, conn, resp)

Initiate a chunked streaming response. Headers are sent immediately; the
producer runs on its own task and writes chunks to a bounded channel which
the event loop drains (`drain_streams!`). The poll thread never runs user
code, so one slow stream cannot stall the server.
"""
function send_stream_response!(server::AbstractServer, conn::MgConnection, resp::StreamResponse)
    # Chunks are written with raw mg_send, which bypasses Mongoose's internal
    # response-framing state; reusing the connection afterwards wedges it.
    # Close after the stream (standard for SSE anyway — each client keeps its
    # own connection) to keep the server safe and predictable.
    headers = string(
        content_type_header_raw(resp.content_type),
        format_headers(resp.headers),
        "Transfer-Encoding: chunked\r\n",
        "Connection: close\r\n"
    )
    head = string("HTTP/1.1 ", resp.status, " ", status_reason(resp.status), "\r\n",
                  headers, "\r\n")
    mg_send(conn, Vector{UInt8}(codeunits(head)))

    chan = Channel{Union{Vector{UInt8},Nothing}}(64)
    server.streams[Int(conn)] = ActiveStream(chan, conn, false)
    producer = resp.producer
    @async _run_stream(chan, producer)
    return nothing
end

function _run_stream(chan::Channel{Union{Vector{UInt8},Nothing}}, producer::Function)
    writer = StreamWriter(chan, true)
    try
        producer(writer)
    catch e
        e isa InvalidStateException ||
            @log_error "Stream producer error" e catch_backtrace()
    finally
        if writer.open
            try
                put!(chan, _STREAM_TERMINAL)
                put!(chan, nothing)
            catch
            end
        end
    end
end

"""
    drain_streams!(server)

Send any pending chunks for in-flight streams. Called from the event loop;
must run on the poll thread only (C connections are not thread-safe).
"""
function drain_streams!(server::AbstractServer)
    streams = server.streams
    isempty(streams) && return
    done = Int[]
    for (id, st) in streams
        chan = st.channel
        while isopen(chan) && isready(chan)
            chunk = take!(chan)
            if chunk === nothing
                push!(done, id)
                break
            end
            mg_send(st.conn, chunk)
        end
    end
    for id in done
        delete!(streams, id)
    end
    return
end

@inline content_type_header_raw(ct::String) = "Content-Type: " * ct * "\r\n"
