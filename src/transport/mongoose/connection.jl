"""
    Connection abstraction — hides raw C pointers behind a safe interface.
    All FFI writes to connections go through these functions.
"""

"""
    send_http_response!(conn, response)

Send a buffered HTTP response through the binary-safe C reply helper. Mongoose
derives `Content-Length` itself, so string and byte bodies are framed
identically and the connection keeps its response state (keep-alive safe).
"""
function send_http_response!(conn::MgConnection, res::Response)
    mgjl_http_reply_bin(conn, res.status, _header_block(res, nothing), res.body)
end

"""
    send_http_response!(conn, response, request_id)

Send response with X-Request-Id header injected.
"""
function send_http_response!(conn::MgConnection, res::Response, rid::String)
    mgjl_http_reply_bin(conn, res.status, _header_block(res, rid), res.body)
end

# One buffer per response header block (no intermediate String concatenation).
function _header_block(res::Response, rid::Union{Nothing,String})::String
    io = IOBuffer(sizehint=128)
    formatheaders(io, res.headers.data)
    rid !== nothing && print(io, "X-Request-Id: ", rid, "\r\n")
    return String(take!(io))
end

"""
    _response_wants_close(res::Response) → Bool

True when the response carries a `Connection: close` token. Mongoose only
marks connections draining from the *request* header, so an explicit response
header (or an echoed client close in async mode) must trigger the close
itself.
"""
@inline function _response_wants_close(res::Response)::Bool
    value = get(res.headers, "connection", nothing)
    value === nothing && return false
    return Kernel._has_token(value, "close")
end

"""
    send_ws_frame!(conn, data)

Send a WebSocket frame (text or binary, auto-detected).
"""
send_ws_frame!(conn::MgConnection, data::String) = mg_ws_send(conn, data, WS_OP_TEXT)
send_ws_frame!(conn::MgConnection, data::Vector{UInt8}) = mg_ws_send(conn, data, WS_OP_BINARY)
send_ws_frame!(conn::MgConnection, msg::Message) = send_ws_frame!(conn, msg.data)

# --- Streaming support ---

"""
    StreamWriter — chunked-encoding writer fed by a task, drained by the loop.

    `write` enqueues the raw payload onto the stream's channel; the event loop
    drains the channel and frames each chunk with `mg_http_write_chunk` on the
    poll thread. Producers therefore never touch the connection directly, and a
    slow producer only blocks its own task (bounded channel = natural
    backpressure), never the event loop.

    `close`/EOF pushes a `nothing` sentinel; the loop then sends the terminal
    zero-length chunk and closes once the socket has drained.
"""
mutable struct StreamWriter <: IO
    channel::Channel{Union{Vector{UInt8},Nothing}}
    open::Bool
end

function Base.write(w::StreamWriter, data::String)
    w.open || error("StreamWriter is closed")
    put!(w.channel, Vector{UInt8}(codeunits(data)))
    return ncodeunits(data)
end

function Base.write(w::StreamWriter, data::Vector{UInt8})
    w.open || error("StreamWriter is closed")
    put!(w.channel, copy(data))
    return length(data)
end

function Base.flush(::StreamWriter)
    # No-op: chunks are drained by the event loop on its next pass.
    nothing
end

function Base.close(w::StreamWriter)
    if w.open
        try
            put!(w.channel, nothing)
        catch e
            e isa InvalidStateException || rethrow(e)
        end
        w.open = false
    end
    return nothing
end

Base.isopen(w::StreamWriter) = w.open

"""
    _prepare_stream(resp) → StreamStart

Prepare a streamed reply in the caller's context: create the bounded chunk
channel and spawn the producer task (concrete producer type). The poll thread
later sends the headers and registers the stream (`send_stream_start!`), so a
worker can prepare a stream without erasing its producer type.
"""
function _prepare_stream(resp::StreamResponse{P}) where {P}
    chan = Channel{Union{Vector{UInt8},Nothing}}(64)
    # A producer must never run on the poll thread: a CPU-bound generator
    # (@async is sticky) would stall mg_mgr_poll, draining, and timeouts.
    Threads.@spawn _run_stream(chan, resp.producer)
    return Kernel.StreamStart(chan, resp.status, resp.content_type, resp.headers)
end

"""
    send_stream_start!(server, conn, start) → nothing

Poll-thread side of a streamed reply: send the headers and register the stream
so `drain_streams!` forwards the producer's chunks.
"""
function send_stream_start!(server::AbstractServer, conn::MgConnection, start::Kernel.StreamStart)
    io = IOBuffer(sizehint=192)
    print(io, "HTTP/1.1 ", start.status, " ", statusreason(start.status), "\r\n",
        "Content-Type: ", start.content_type, "\r\n")
    formatheaders(io, start.headers.data)
    write(io, "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    mg_send(conn, take!(io))
    server.runtime.streams[Int(conn)] = ActiveStream(start.chan, conn, false)
    return nothing
end

"""
    send_stream_response!(server, conn, resp)

Initiate a chunked streaming response on the poll thread (sync mode): prepare
the stream and send its headers.
"""
function send_stream_response!(server::AbstractServer, conn::MgConnection, resp::StreamResponse{P}) where {P}
    send_stream_start!(server, conn, _prepare_stream(resp))
    return nothing
end

function _run_stream(chan::Channel{Union{Vector{UInt8},Nothing}}, producer::P) where {P}
    writer = StreamWriter(chan, true)
    try
        producer(writer)
    catch e
        e isa InvalidStateException ||
            @log_error "Stream producer error" e catch_backtrace()
    finally
        if writer.open
            try
                put!(chan, nothing)
            catch
            end
        end
    end
    return nothing
end

"""
    drain_streams!(server)

Send any pending chunks for in-flight streams. Called from the event loop;
must run on the poll thread only (C connections are not thread-safe).
"""
# Bytes queued in Mongoose's send buffer for this connection (not yet accepted
# by the socket). Poll-thread only.
@inline _send_buffered(conn::MgConnection)::Int = mgjl_conn_send_len(conn)

function drain_streams!(server::AbstractServer)
    streams = server.runtime.streams
    isempty(streams) && return
    cap = server.config.send_buffer_bytes
    done = Int[]
    for (id, st) in streams
        chan = st.channel
        while isopen(chan) && isready(chan)
            # Backpressure: full send buffer stops feeding; chunks stay in the channel.
            cap > 0 && _send_buffered(st.conn) >= cap && break
            chunk = take!(chan)
            if chunk === nothing
                # Terminal chunk: also clears mongoose's response state.
                mg_http_write_chunk(st.conn, UInt8[])
                mgjl_conn_close_after_send(st.conn)
                push!(done, id)
                break
            end
            mg_http_write_chunk(st.conn, chunk)
        end
    end
    for id in done
        delete!(streams, id)
    end
    return nothing
end
