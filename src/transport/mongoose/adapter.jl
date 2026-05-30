"""
    Transport adapter — converts Mongoose C FFI types into pure-Julia Request objects.

    This is the ONLY place where FFI structs cross into the application layer.
    Everything above this layer works with pure Julia types exclusively.
"""

"""
    adapt_request(msg::MgHttpMessage) → Request

Convert a Mongoose C HTTP message into a transport-agnostic Request.
This is the single point of FFI→Julia boundary crossing for requests.
"""
function adapt_request(msg::MgHttpMessage)::Request
    method = parse_method(msg.method)
    uri = to_string(msg.uri)
    query_str = to_string(msg.query)
    query = parse_query(query_str)
    headers = parse_headers(msg)
    body = to_string(msg.body)
    path = strip_query(uri)
    return Request(method, uri, String(path), query, headers, body, nothing)
end

"""
    adapt_request(msg::MgHttpMessage, method::Symbol, uri::String) → Request

Fast-path adapter reusing pre-extracted method and URI (avoids redundant C→Julia conversion).
"""
function adapt_request(msg::MgHttpMessage, method::Symbol, uri::String)::Request
    query_str = to_string(msg.query)
    query = parse_query(query_str)
    headers = parse_headers(msg)
    body = to_string(msg.body)
    path = String(strip_query(uri))
    return Request(method, uri, path, query, headers, body, nothing)
end

"""
    adapt_request_minimal(msg::MgHttpMessage) → Request

Minimal adapter for WebSocket upgrade — only method, URI, query, and headers.
Skips body parsing (WebSocket upgrade requests have no meaningful body).
"""
function adapt_request_minimal(msg::MgHttpMessage)::Request
    method = parse_method(msg.method)
    uri = to_string(msg.uri)
    query_str = to_string(msg.query)
    query = parse_query(query_str)
    headers = parse_headers(msg)
    path = String(strip_query(uri))
    return Request(method, uri, path, query, headers, "", nothing)
end

# --- Internal conversion helpers ---

@inline function to_string(str::MgStr)::String
    (str.buf == C_NULL || str.len == 0) && return ""
    return unsafe_string(str.buf, str.len)
end

"""
    parse_method(str::MgStr) → Symbol

Zero-allocation HTTP method parsing via direct byte comparison.
"""
@inline function parse_method(str::MgStr)::Symbol
    (str.buf == C_NULL || str.len == 0) && return :unknown
    ptr = str.buf
    len = str.len
    b1 = unsafe_load(ptr, 1)

    if b1 == 0x47 && len == 3  # GET
        unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x54 && return :get
    elseif b1 == 0x50  # P...
        if len == 3  # PUT
            unsafe_load(ptr, 2) == 0x55 && unsafe_load(ptr, 3) == 0x54 && return :put
        elseif len == 4  # POST
            unsafe_load(ptr, 2) == 0x4F && unsafe_load(ptr, 3) == 0x53 && unsafe_load(ptr, 4) == 0x54 && return :post
        elseif len == 5  # PATCH
            unsafe_load(ptr, 2) == 0x41 && unsafe_load(ptr, 3) == 0x54 && unsafe_load(ptr, 4) == 0x43 && unsafe_load(ptr, 5) == 0x48 && return :patch
        end
    elseif b1 == 0x44 && len == 6  # DELETE
        unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x4C && unsafe_load(ptr, 4) == 0x45 &&
        unsafe_load(ptr, 5) == 0x54 && unsafe_load(ptr, 6) == 0x45 && return :delete
    elseif b1 == 0x4F && len == 7  # OPTIONS
        unsafe_load(ptr, 2) == 0x50 && unsafe_load(ptr, 3) == 0x54 && unsafe_load(ptr, 4) == 0x49 &&
        unsafe_load(ptr, 5) == 0x4F && unsafe_load(ptr, 6) == 0x4E && unsafe_load(ptr, 7) == 0x53 && return :options
    elseif b1 == 0x48 && len == 4  # HEAD
        unsafe_load(ptr, 2) == 0x45 && unsafe_load(ptr, 3) == 0x41 && unsafe_load(ptr, 4) == 0x44 && return :head
    end
    return Symbol(lowercase(to_string(str)))
end

"""
    parse_headers(msg::MgHttpMessage) → Headers

Extract and normalize headers from C struct. Names are lowercased in a single pass.
"""
function parse_headers(msg::MgHttpMessage)::Headers
    pairs = Pair{String,String}[]
    sizehint!(pairs, 12)
    for h in msg.headers
        h.name.buf == C_NULL && break
        h.name.len == 0 && break
        if h.val.buf != C_NULL && h.val.len > 0
            name = lowercase_string(h.name)
            value = to_string(h.val)
            push!(pairs, name => value)
        end
    end
    return Headers(pairs)
end

"""
    lowercase_string(str::MgStr) → String

Single-pass lowercase + string allocation from C data. Avoids double allocation
of `lowercase(unsafe_string(...))`.
"""
@inline function lowercase_string(str::MgStr)::String
    len = Int(str.len)
    buf = Vector{UInt8}(undef, len)
    src = str.buf
    @inbounds for i in 1:len
        buf[i] = to_lower(unsafe_load(src, i))
    end
    return String(buf)
end
