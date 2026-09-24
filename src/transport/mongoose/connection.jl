"""
    Connection abstraction — hides raw C pointers behind a safe interface.
    All FFI writes to connections go through these functions.
"""

"""
    send_http_response!(conn, response)

Send a buffered HTTP response via mongoose's native framing: string bodies go
through `mg_http_reply` (Content-Length derived by mongoose, keep-alive reuse
safe), binary bodies are hand-framed with `mg_send` and always advertise
`Connection: close` — hand-framed frames bypass mongoose's response-framing
state, so the socket must not be reused (streams follow the same rule).
"""
function send_http_response!(conn::MgConnection, res::Response)
    if res.body isa Vector{UInt8}
        _send_binary_response!(conn, res.status, _header_block(res, nothing, true), res.body)
    else
        mg_http_reply(conn, res.status, _header_block(res, nothing, false), res.body)
    end
end

"""
    send_http_response!(conn, response, request_id)

Send response with X-Request-Id header injected.
"""
function send_http_response!(conn::MgConnection, res::Response, rid::String)
    if res.body isa Vector{UInt8}
        _send_binary_response!(conn, res.status, _header_block(res, rid, true), res.body)
    else
        mg_http_reply(conn, res.status, _header_block(res, rid, false), res.body)
    end
end

# One buffer per response header block (no intermediate String concatenation).
# `close_raw` adds `Connection: close` for hand-framed (binary) bodies, which
# leave mongoose without response-framing state and must not be reused.
function _header_block(res::Response, rid::Union{Nothing,String}, close_raw::Bool)::String
    io = IOBuffer(sizehint=128)
    formatheaders(io, res.headers.data)
    rid !== nothing && print(io, "X-Request-Id: ", rid, "\r\n")
    if close_raw && get(res.headers, "connection", nothing) === nothing
        write(io, "Connection: close\r\n")
    end
    return String(take!(io))
end

"""
    send_ws_frame!(conn, data)

Send a WebSocket frame (text or binary, auto-detected).
"""
send_ws_frame!(conn::MgConnection, data::String) = mg_ws_send(conn, data, WS_OP_TEXT)
send_ws_frame!(conn::MgConnection, data::Vector{UInt8}) = mg_ws_send(conn, data, WS_OP_BINARY)
send_ws_frame!(conn::MgConnection, msg::Message) = send_ws_frame!(conn, msg.data)

# --- Internal binary response assembly ---


function _send_binary_response!(conn::MgConnection, status::Int, headers::String, body::Vector{UInt8})
    status_text = statusreason(status)
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
    io = IOBuffer(sizehint=192)
    print(io, "HTTP/1.1 ", resp.status, " ", statusreason(resp.status), "\r\n",
        "Content-Type: ", resp.content_type, "\r\n")
    formatheaders(io, resp.headers.data)
    write(io, "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    mg_send(conn, take!(io))

    chan = Channel{Union{Vector{UInt8},Nothing}}(64)
    server.runtime.streams[Int(conn)] = ActiveStream(chan, conn, false)
    producer = resp.producer
    # A producer must never run on the poll thread: a CPU-bound generator
    # (@async is sticky) would stall mg_mgr_poll, draining, and timeouts.
    Threads.@spawn _run_stream(chan, producer)
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
# Bytes queued in Mongoose's send buffer for this connection (not yet accepted
# by the socket). Poll-thread only.
@inline _send_buffered(conn::MgConnection)::Int =
    Int(unsafe_load(Ptr{Csize_t}(reinterpret(UInt, conn) + _MG_CONN_SEND_LEN_OFFSET)))

function drain_streams!(server::AbstractServer)
    streams = server.runtime.streams
    isempty(streams) && return
    cap = server.config.send_buffer_bytes
    done = Int[]
    for (id, st) in streams
        chan = st.channel
        while isopen(chan) && isready(chan)
            # Backpressure: stop feeding a connection whose unsent buffer is
            # full. Chunks stay in the bounded channel (the producer blocks),
            # so a slow reader cannot grow server memory without bound.
            cap > 0 && _send_buffered(st.conn) >= cap && break
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
