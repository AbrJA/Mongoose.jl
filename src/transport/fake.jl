"""
    FakeStream — one in-flight streaming response owned by a `FakeTransport`.

    A stream is created when the transport delivers a `StreamResponse`. Its
    producer writes into `io` through the `FakeStreamWriter` while `open`; when
    the response is delivered the stream is marked `done` and further writes
    raise `StreamClosedError` (one response per stream). `error` records a
    producer exception, if any. Ownership is the registry on the transport —
    `close!(transport)` flips `open`/`done` on every owned stream (cascade).
"""
mutable struct FakeStream
    io::IOBuffer
    open::Bool
    done::Bool
    error::Union{Nothing,Exception}
end

"""
    StreamClosedError — write attempted on a closed/consumed stream.

    Raised by `FakeStreamWriter` when the owning `FakeTransport` was closed, or
    when the stream already delivered its one response.
"""
struct StreamClosedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::StreamClosedError) = print(io, "StreamClosedError: ", e.msg)

"""
    FakeTransport — reference transport that runs the pipeline with no FFI.

    A `TestClient` really is a fake transport: it dispatches requests directly
    through the middleware pipeline and router (`process`), bypassing
    the C event loop entirely. It declares its capabilities via the ability
    traits (`supportsws`, `supportstls`, `supportsstream`): no WebSocket,
    no TLS, streaming supported. It can
    drive a full request cycle without a running server — including on systems
    where `Mongoose_jll` was never loaded.

    The transport is **stateful**: it owns a registry of in-flight streams
    (`transport.streams`). A streamed response is bound to exactly one
    `FakeStream` — after it is delivered (producer completes) the stream is
    `done`, and any further write raises `StreamClosedError` (one response per
    stream). `close!(transport)` closes every owned stream (writers become
    closed) and rejects new requests, modeling the C transport's close cascade.

    # Example
    ```julia
    app = App()
    get!(app, "/hello") do req
        json((message="Hello World",))
    end

    client = FakeTransport(app)      # alias: TestClient(app)
    resp = client(:get, "/hello")
    @assert resp.status == 200
    @assert contains(resp.body, "Hello World")
    ```
"""
mutable struct FakeTransport <: AbstractTransport
    app::App
    stream_seq::Int
    streams::Dict{Int,FakeStream}
    closed::Bool
end

FakeTransport(app::App) = FakeTransport(app, 0, Dict{Int,FakeStream}(), false)

"""Backward-compatible name for `FakeTransport`.

The old `TestClient` name is kept as an alias so the FFI-free transport is
both obvious and familiar.
"""
const TestClient = FakeTransport

supportsws(::FakeTransport) = false
supportstls(::FakeTransport) = false
supportsstream(::FakeTransport) = true

# --- Owner-aware stream writer (replaces the old stateless StreamWriterBuffer) ---

"""
    FakeStreamWriter — IO handed to a streamed response's producer.

    Writes append to the owning `FakeStream.io` while the stream is open;
    writing after `close!` of the transport or after the stream delivered its
    response raises `StreamClosedError`.
"""
mutable struct FakeStreamWriter <: IO
    stream::FakeStream
end

@inline function _ensure_writable(st::FakeStream)
    (st.open && !st.done) || throw(StreamClosedError("stream is closed (one response per stream)"))
    return nothing
end

Base.write(w::FakeStreamWriter, data::UInt8) = (_ensure_writable(w.stream); write(w.stream.io, data); 1)
Base.write(w::FakeStreamWriter, data::Vector{UInt8}) = (_ensure_writable(w.stream); write(w.stream.io, data); length(data))
Base.write(w::FakeStreamWriter, data::String) = (_ensure_writable(w.stream); write(w.stream.io, data); ncodeunits(data))
Base.flush(::FakeStreamWriter) = nothing
Base.isopen(w::FakeStreamWriter) = w.stream.open && !w.stream.done

function Base.close(w::FakeStreamWriter)
    st = w.stream
    st.open = false
    st.done = true
    return nothing
end

# --- Close cascade ---

"""
    close!(transport::FakeTransport)

Close the transport: every owned stream is closed (its writer becomes closed)
and further requests raise an error.
"""
function close!(transport::FakeTransport)
    transport.closed = true
    for st in values(transport.streams)
        st.open = false
        st.done = true
    end
    return transport
end

# --- Stream execution: one response, bound to one stream ---

function _run_fake_stream(transport::FakeTransport, resp::StreamResponse)::Response
    transport.stream_seq += 1
    id = transport.stream_seq
    stream = FakeStream(IOBuffer(), true, false, nothing)
    transport.streams[id] = stream
    writer = FakeStreamWriter(stream)
    try
        resp.producer(writer)
    catch e
        stream.error = e
    finally
        stream.open = false
        stream.done = true          # one response per stream, then closed
    end
    body = String(take!(stream.io))
    return Response(resp.status,
                    mergeheaders(resp.headers, ["Content-Type" => resp.content_type]; prepend=true),
                    body)
end

"""
    (client::TestClient)(method, path; headers=[], body="", query=Dict(), remote_addr="127.0.0.1") → Response

Execute a request against the app without network I/O. `remote_addr` sets the
request's peer address (defaults to a loopback client; pass `nothing` for a
transport-less request).
"""
function (client::FakeTransport)(method::Symbol, path::String;
                                 headers::Vector{Pair{String,String}}=Pair{String,String}[],
                                 body::String="",
                                 query::Dict{String,String}=Dict{String,String}(),
                                 remote_addr::Union{Nothing,String}="127.0.0.1")
    client.closed && throw(StreamClosedError("transport is closed"))
    # Build URI with query string
    uri = if isempty(query)
        path
    else
        params = join(["$k=$(_url_encode(v))" for (k, v) in query], "&")
        "$path?$params"
    end

    # Merge query from path if present
    parsed_query = parsequery(stripquery(uri) == uri ? "" : String(uri[length(stripquery(uri))+2:end]))
    merge!(parsed_query, query)

    req_path = String(stripquery(uri))
    req = Request(method, uri, req_path, parsed_query, Headers(headers), body, nothing, remote_addr)

    # Run through pipeline exactly as the real server would
    result = try
        invoke_http(client.app, req)
    catch e
        errorresponse(client.app.errors, req, 500)
    end

    if result isa StreamResponse
        return _run_fake_stream(client, result)
    end

    return result::Response
end

# Convenience methods
function (client::FakeTransport)(method::Symbol, path::String, json_body;
                                 headers::Vector{Pair{String,String}}=Pair{String,String}[],
                                 query::Dict{String,String}=Dict{String,String}())
    body = JSON.json(json_body)
    all_headers = ["content-type" => "application/json"; headers]
    return client(method, path; headers=all_headers, body=body, query=query)
end

# Simple URL encoding for test client query params
function _url_encode(s::String)::String
    io = IOBuffer()
    for c in s
        if c == ' '
            write(io, '+')
        elseif isascii(c) && (isletter(c) || isdigit(c) || c in "-_.~")
            write(io, c)
        else
            for b in codeunits(string(c))
                write(io, '%', string(b, base=16, pad=2))
            end
        end
    end
    return String(take!(io))
end
