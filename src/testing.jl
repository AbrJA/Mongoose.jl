"""
    TestClient — Test applications without network I/O.

    Dispatches requests directly through the middleware pipeline and router,
    bypassing the C event loop entirely. Useful for unit and integration testing.

    # Example
    ```julia
    using Mongoose: TestClient

    app = App()
    get!(app, "/hello") do req
        json((message="Hello World",))
    end

    client = TestClient(app)
    resp = client(:get, "/hello")
    @assert resp.status == 200
    @assert contains(resp.body, "Hello World")
    ```
"""
struct TestClient
    app::App
end

"""
    (client::TestClient)(method, path; headers=[], body="", query=Dict()) → Response

Execute a request against the app without network I/O.
"""
function (client::TestClient)(method::Symbol, path::String;
                               headers::Vector{Pair{String,String}}=Pair{String,String}[],
                               body::String="",
                               query::Dict{String,String}=Dict{String,String}())
    # Build URI with query string
    uri = if isempty(query)
        path
    else
        params = join(["$k=$(HTTP_encode(v))" for (k, v) in query], "&")
        "$path?$params"
    end

    # Merge query from path if present
    parsed_query = parse_query(strip_query(uri) == uri ? "" : String(uri[length(strip_query(uri))+2:end]))
    merge!(parsed_query, query)

    req_path = String(strip_query(uri))
    req = Request(method, uri, req_path, parsed_query, Headers(headers), body, nothing)

    # Run through pipeline exactly as the real server would
    result = try
        invoke_http(client.app, req)
    catch e
        error_response(client.app, req, 500)
    end

    if result isa StreamResponse
        # Capture stream output
        io = IOBuffer()
        sw = StreamWriterBuffer(io)
        try
            result.producer(sw)
        catch end
        return Response(result.status,
            ["Content-Type" => result.content_type; result.headers],
            String(take!(io)))
    end

    return result::Response
end

# Convenience methods
function (client::TestClient)(method::Symbol, path::String, json_body;
                               headers::Vector{Pair{String,String}}=Pair{String,String}[],
                               query::Dict{String,String}=Dict{String,String}())
    body = JSON.json(json_body)
    all_headers = ["content-type" => "application/json"; headers]
    return client(method, path; headers=all_headers, body=body, query=query)
end

# Simple URL encoding for test client query params
function HTTP_encode(s::String)::String
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

# Buffer-based StreamWriter for TestClient (captures output without network)
struct StreamWriterBuffer <: IO
    io::IOBuffer
end
Base.write(w::StreamWriterBuffer, data::UInt8) = write(w.io, data)
Base.write(w::StreamWriterBuffer, data::Vector{UInt8}) = write(w.io, data)
Base.write(w::StreamWriterBuffer, data::String) = write(w.io, data)
Base.flush(::StreamWriterBuffer) = nothing
Base.isopen(::StreamWriterBuffer) = true
