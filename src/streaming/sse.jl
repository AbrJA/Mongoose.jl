"""
    Server-Sent Events (SSE) support.

    Provides a high-level API for streaming real-time events to clients
    using the W3C EventSource protocol.
"""

"""
    SSEWriter — Writes Server-Sent Events to a connection.

    Used within a `StreamResponse` producer:
    ```julia
    function sse_handler(req)
        StreamResponse(200; content_type="text/event-stream",
                       headers=["Cache-Control" => "no-cache", "Connection" => "keep-alive"]) do writer
            sse = SSEWriter(writer)
            for i in 1:10
                event!(sse; data="tick \$i", event="heartbeat", id=string(i))
                sleep(1.0)
            end
        end
    end
    ```
"""
struct SSEWriter
    writer::StreamWriter
end

"""
    event!(sse; data, event="", id="", retry=nothing)

Send a single SSE event. Fields:
- `data::String` — event payload (required). Multi-line data is handled correctly.
- `event::String` — event type/name (optional).
- `id::String` — event ID for reconnection (optional).
- `retry::Union{Nothing,Int}` — reconnection interval in ms (optional).
"""
function event!(sse::SSEWriter; data::String, event::String="", id::String="", retry::Union{Nothing,Int}=nothing)
    io = IOBuffer(sizehint=64 + ncodeunits(data))
    !isempty(id) && (print(io, "id: ", id, "\n"))
    !isempty(event) && (print(io, "event: ", event, "\n"))
    retry !== nothing && (print(io, "retry: ", retry, "\n"))
    for line in eachsplit(data, '\n')
        print(io, "data: ", line, "\n")
    end
    print(io, "\n")  # blank line terminates the event
    write(sse.writer, String(take!(io)))
end

"""
    sse_response(producer; headers=[]) → StreamResponse

Convenience constructor for SSE responses with correct headers.

```julia
function stream_events(req)
    sse_response() do writer
        sse = SSEWriter(writer)
        event!(sse; data="hello", event="greeting")
    end
end
```
"""
function sse_response(producer::Function;
                      headers::Vector{Pair{String,String}}=["Cache-Control" => "no-cache",
                                                            "Connection" => "keep-alive",
                                                            "X-Accel-Buffering" => "no"])
    return StreamResponse(producer, 200; content_type="text/event-stream", headers=headers)
end
