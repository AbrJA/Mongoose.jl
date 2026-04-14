#!/usr/bin/env julia
#
# buildbin/testing.jl — Compile + smoke-test the juliac trim=safe binary.
# Run from the repository root:
#
#   julia --project buildbin/testing.jl
#
# This script:
#   1. Compiles example/juliac/server.jl with juliac --trim=safe
#   2. Starts the binary
#   3. Runs comprehensive HTTP smoke tests (routes, methods, formats,
#      query parsing, context, mount!, fail!, custom headers, binary body)
#   4. Kills the binary and reports results
#
# Exit code 0 = all checks passed.

using Base64
using Random
using SHA
using Sockets

const ROOT = dirname(@__DIR__)
const SRC  = joinpath(ROOT, "example", "juliac", "server.jl")
const BIN  = joinpath(ROOT, "binary")
const HOST = "127.0.0.1"
const PORT = 8099
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
const WS_TEXT = UInt8(0x1)
const WS_BINARY = UInt8(0x2)
const WS_CLOSE = UInt8(0x8)
const WS_PING = UInt8(0x9)
const WS_PONG = UInt8(0xA)

mutable struct WsClient
    sock::TCPSocket
    buffer::Vector{UInt8}
end

# ── Helpers ──────────────────────────────────────────

"""Find byte-offset of first \\r\\n\\r\\n in `data`; 0 if not found."""
function _find_hdr_end(data::Vector{UInt8})
    n = length(data)
    n < 4 && return 0
    @inbounds for i in 1:n-3
        data[i] == 0x0d && data[i+1] == 0x0a &&
        data[i+2] == 0x0d && data[i+3] == 0x0a && return i
    end
    return 0
end

"""Parse Content-Length value from header bytes `data[1:sep-1]`."""
function _read_cl(data::Vector{UInt8}, sep::Int)
    hdr = String(view(data, 1:sep-1))
    for line in split(hdr, "\r\n")
        startswith(lowercase(line), "content-length:") || continue
        return tryparse(Int, strip(line[16:end]))
    end
    return nothing
end

function _read_http_response(sock::TCPSocket, method::String; timeout=5)
    data = UInt8[]
    deadline = time() + timeout
    sep = 0

    while sep == 0 && time() < deadline
        isopen(sock) || break
        chunk = readavailable(sock)
        if isempty(chunk)
            sleep(0.01)
            continue
        end
        append!(data, chunk)
        sep = _find_hdr_end(data)
    end

    sep == 0 && return String(data)

    body_off = sep + 4
    cl = _read_cl(data, sep)

    if method == "HEAD"
        nothing
    elseif cl !== nothing && cl > 0
        while length(data) - body_off + 1 < cl && time() < deadline
            isopen(sock) || break
            chunk = readavailable(sock)
            if isempty(chunk)
                sleep(0.01)
                continue
            end
            append!(data, chunk)
        end
    elseif cl === nothing
        while isopen(sock) && time() < deadline
            chunk = readavailable(sock)
            if isempty(chunk)
                sleep(0.01)
                continue
            end
            append!(data, chunk)
        end
    end

    return String(data)
end

function http_request(host, port, method, path; body="", headers=Pair{String,String}[], timeout=5)
    sock = nothing
    try
        sock = connect(host, port)
        buf = IOBuffer()
        write(buf, method, " ", path, " HTTP/1.1\r\n")
        write(buf, "Host: ", host, ":", string(port), "\r\n")
        for (k, v) in headers
            write(buf, k, ": ", v, "\r\n")
        end
        if !isempty(body)
            write(buf, "Content-Length: ", string(sizeof(body)), "\r\n")
        end
        write(buf, "Connection: close\r\n\r\n")
        !isempty(body) && write(buf, body)
        write(sock, take!(buf))
        return _read_http_response(sock, method; timeout=timeout)
    catch
        return ""
    finally
        sock !== nothing && isopen(sock) && close(sock)
    end
end

http_get(path; kw...)      = http_request(HOST, PORT, "GET",    path; kw...)
http_post(path, b; kw...)  = http_request(HOST, PORT, "POST",   path; body=b, kw...)
http_put(path, b; kw...)   = http_request(HOST, PORT, "PUT",    path; body=b, kw...)
http_patch(path; kw...)    = http_request(HOST, PORT, "PATCH",  path; kw...)
http_delete(path; kw...)   = http_request(HOST, PORT, "DELETE", path; kw...)
http_head(path; kw...)     = http_request(HOST, PORT, "HEAD",   path; kw...)

function parse_status(raw::String)
    m = match(r"HTTP/1\.\d (\d+)", raw)
    m === nothing ? 0 : parse(Int, m.captures[1])
end

function parse_body(raw::String)
    idx = findfirst("\r\n\r\n", raw)
    idx === nothing ? "" : raw[last(idx)+1:end]
end

function parse_header(raw::String, name::String)
    lname = lowercase(name)
    for line in split(raw, "\r\n")
        if startswith(lowercase(line), lname * ":")
            return strip(line[length(name)+2:end])
        end
    end
    return nothing
end

function wait_for_server(host, port; timeout=15.0)
    deadline = time() + timeout
    while time() < deadline
        try; sock = connect(host, port); close(sock); return true; catch; sleep(0.2); end
    end
    return false
end

function _ws_take!(client::WsClient, n::Int; timeout=5)
    deadline = time() + timeout
    while length(client.buffer) < n && time() < deadline
        isopen(client.sock) || break
        chunk = readavailable(client.sock)
        if isempty(chunk)
            sleep(0.01)
            continue
        end
        append!(client.buffer, chunk)
    end
    length(client.buffer) < n && error("WebSocket read timed out")
    data = copy(client.buffer[1:n])
    client.buffer = n == length(client.buffer) ? UInt8[] : client.buffer[n+1:end]
    return data
end

function _ws_read_headers!(client::WsClient; timeout=5)
    deadline = time() + timeout
    sep = _find_hdr_end(client.buffer)
    while sep == 0 && time() < deadline
        isopen(client.sock) || break
        chunk = readavailable(client.sock)
        if isempty(chunk)
            sleep(0.01)
            continue
        end
        append!(client.buffer, chunk)
        sep = _find_hdr_end(client.buffer)
    end
    sep == 0 && error("WebSocket handshake timed out")
    hdr_end = sep + 3
    raw = String(copy(client.buffer[1:hdr_end]))
    client.buffer = hdr_end == length(client.buffer) ? UInt8[] : client.buffer[hdr_end+1:end]
    return raw
end

function _ws_accept(key::String)
    return base64encode(sha1(key * WS_GUID))
end

function ws_open(path; headers=Pair{String,String}[], timeout=5)
    sock = connect(HOST, PORT)
    client = WsClient(sock, UInt8[])
    key = base64encode(rand(UInt8, 16))

    buf = IOBuffer()
    write(buf, "GET ", path, " HTTP/1.1\r\n")
    write(buf, "Host: ", HOST, ":", string(PORT), "\r\n")
    write(buf, "Upgrade: websocket\r\n")
    write(buf, "Connection: Upgrade\r\n")
    write(buf, "Sec-WebSocket-Key: ", key, "\r\n")
    write(buf, "Sec-WebSocket-Version: 13\r\n")
    for (k, v) in headers
        write(buf, k, ": ", v, "\r\n")
    end
    write(buf, "\r\n")
    write(sock, take!(buf))

    raw = _ws_read_headers!(client; timeout=timeout)
    parse_status(raw) == 101 || error("WebSocket upgrade failed: " * raw)
    parse_header(raw, "Sec-WebSocket-Accept") == _ws_accept(key) || error("Invalid WebSocket accept header")
    return client
end

function ws_send_frame(client::WsClient, opcode::UInt8, payload::Vector{UInt8}=UInt8[]; fin=true)
    len = length(payload)
    len <= typemax(UInt16) || error("Payload too large for smoke test WebSocket client")

    buf = IOBuffer()
    first = (fin ? 0x80 : 0x00) | Int(opcode)
    write(buf, UInt8(first))
    if len < 126
        write(buf, UInt8(0x80 | len))
    else
        write(buf, UInt8(0x80 | 126))
        write(buf, UInt8((len >> 8) & 0xff))
        write(buf, UInt8(len & 0xff))
    end

    mask = rand(UInt8, 4)
    write(buf, mask)
    masked = similar(payload)
    for i in eachindex(payload)
        masked[i] = xor(payload[i], mask[mod1(i, 4)])
    end
    write(buf, masked)
    write(client.sock, take!(buf))
    return nothing
end

function ws_send_text(client::WsClient, text::String)
    ws_send_frame(client, WS_TEXT, collect(codeunits(text)))
end

function ws_send_binary(client::WsClient, bytes::Vector{UInt8})
    ws_send_frame(client, WS_BINARY, bytes)
end

function ws_receive_frame(client::WsClient; timeout=5)
    hdr = _ws_take!(client, 2; timeout=timeout)
    opcode = hdr[1] & 0x0f
    masked = (hdr[2] & 0x80) != 0
    len_tag = Int(hdr[2] & 0x7f)

    len = if len_tag < 126
        len_tag
    elseif len_tag == 126
        ext = _ws_take!(client, 2; timeout=timeout)
        (Int(ext[1]) << 8) | Int(ext[2])
    else
        error("Unsupported 64-bit WebSocket payload in smoke test")
    end

    mask = masked ? _ws_take!(client, 4; timeout=timeout) : UInt8[]
    payload = len == 0 ? UInt8[] : _ws_take!(client, len; timeout=timeout)
    if masked
        for i in eachindex(payload)
            payload[i] = xor(payload[i], mask[mod1(i, 4)])
        end
    end
    return opcode, payload
end

function ws_close(client::WsClient)
    try
        ws_send_frame(client, WS_CLOSE)
        ws_receive_frame(client; timeout=1)
    catch
    finally
        isopen(client.sock) && close(client.sock)
    end
    return nothing
end

# ── Compile ──────────────────────────────────────────

# No precompile step needed: @log_* macros select their backend at expansion time
# (compile time), not via a runtime const. juliac sees only trim-safe print
# calls because LOG_NATIVE is unset.
println("┌─ Compiling with juliac --trim=safe …")
t0 = time()
compile_cmd = Cmd(`juliac --trim=safe --project $ROOT --output-exe binary $SRC`; dir=ROOT)
compile = run(pipeline(compile_cmd; stderr=stderr); wait=true)
if compile.exitcode != 0
    printstyled("│  ✗ Compilation failed (exit $(compile.exitcode))\n"; color=:red, bold=true)
    exit(1)
end
elapsed = round(time() - t0; digits=1)
size_mb = round(filesize(BIN) / 1024 / 1024; digits=1)
printstyled("│  ✓ Compiled → binary ($(size_mb) MB, $(elapsed)s)\n"; color=:green)

# ── Start ────────────────────────────────────────────

println("├─ Starting binary …")
proc = run(Cmd(`$BIN`; dir=ROOT); wait=false)

if !wait_for_server(HOST, PORT)
    printstyled("│  ✗ Binary did not start within timeout\n"; color=:red, bold=true)
    kill(proc)
    exit(1)
end
printstyled("│  ✓ Binary started (pid=$(getpid(proc)))\n"; color=:green)

# ── Tests ────────────────────────────────────────────

passed = 0
failed = 0

function check(label, ok; detail="")
    global passed, failed
    if ok
        printstyled("│  ✓ $label\n"; color=:green)
        passed += 1
    else
        printstyled("│  ✗ $label\n"; color=:red, bold=true)
        !isempty(detail) && printstyled("│    $detail\n"; color=:light_black)
        failed += 1
    end
end

println("├─ Running smoke tests …")
println("│")

# ── GET routes ───────────────────────────────────────
printstyled("│  ── GET routes ──\n"; color=:cyan)

raw = http_get("/")
check("GET /  → 200 HTML",
    parse_status(raw) == 200 && occursin("Mongoose.jl", parse_body(raw)))

raw = http_get("/hello")
check("GET /hello → 200 JSON",
    parse_status(raw) == 200 && occursin("Hello World from trimmed Julia!", parse_body(raw)))

raw = http_get("/health")
check("GET /health → 200",
    parse_status(raw) == 200 && occursin("\"status\":\"ok\"", parse_body(raw)))

raw = http_get("/echo/World")
check("GET /echo/World → 200 name param",
    parse_status(raw) == 200 && occursin("Hello World!", parse_body(raw)))

raw = http_get("/user/42")
check("GET /user/42 → 200 typed Int param",
    parse_status(raw) == 200 && occursin("\"id\":42", parse_body(raw)))

raw = http_get("/user/abc")
check("GET /user/abc → 404 (type mismatch)",
    parse_status(raw) == 404)

# ── Response formats ─────────────────────────────────
println("│")
printstyled("│  ── Response formats ──\n"; color=:cyan)

raw = http_get("/format/json")
check("JSON format → Content-Type: application/json",
    parse_status(raw) == 200 && occursin("application/json", raw))

raw = http_get("/format/plain")
check("Plain format → default Content-Type: text/plain",
    parse_status(raw) == 200 && occursin("text/plain", raw) && parse_body(raw) == "plain response body")

raw = http_get("/format/html")
check("HTML format → Content-Type: text/html",
    parse_status(raw) == 200 && occursin("text/html", raw))

raw = http_get("/format/xml")
check("XML format → Content-Type: application/xml",
    parse_status(raw) == 200 && occursin("application/xml", raw) && occursin("<status>ok</status>", parse_body(raw)))

raw = http_get("/format/css")
check("CSS format → Content-Type: text/css",
    parse_status(raw) == 200 && occursin("text/css", raw))

raw = http_get("/format/js")
check("JS format → Content-Type: application/javascript",
    parse_status(raw) == 200 && occursin("application/javascript", raw))

raw = http_get("/format/binary")
check("Binary format → Content-Type: application/octet-stream",
    parse_status(raw) == 200 && occursin("application/octet-stream", raw))

raw = http_get("/format/binary/typed")
check("Binary Response(Binary, bytes) → typed constructor works",
    parse_status(raw) == 200 && occursin("application/octet-stream", raw) && sizeof(parse_body(raw)) == 4)

# ── CRUD methods ─────────────────────────────────────
println("│")
printstyled("│  ── HTTP methods (CRUD) ──\n"; color=:cyan)

raw = http_post("/items", "{\"name\":\"test\"}")
check("POST /items → 201 Created",
    parse_status(raw) == 201 && occursin("\"received\":{\"name\":\"test\"}", parse_body(raw)))

raw = http_put("/items/7", "{\"name\":\"new\"}")
check("PUT /items/7 → 200 + body",
    parse_status(raw) == 200 && occursin("\"updated\":7", parse_body(raw)))

raw = http_patch("/items/7")
check("PATCH /items/7 → 200",
    parse_status(raw) == 200 && occursin("\"patched\":7", parse_body(raw)))

raw = http_delete("/items/7")
check("DELETE /items/7 → 204 No Content",
    parse_status(raw) == 204)

# ── HEAD auto-handler ────────────────────────────────
raw = http_head("/hello")
check("HEAD /hello → 200 (empty body)",
    parse_status(raw) == 200 && isempty(strip(parse_body(raw))))

raw = http_head("/head-probe")
check("HEAD /head-probe → headers preserved, empty body",
    parse_status(raw) == 200 && parse_header(raw, "X-Head-Check") == "yes" && isempty(strip(parse_body(raw))))

# ── Query parsing ────────────────────────────────────
println("│")
printstyled("│  ── Features ──\n"; color=:cyan)

raw = http_get("/search?q=hello&page=3")
check("Query parsing → struct(q,page)",
    parse_status(raw) == 200 && occursin("\"q\":\"hello\"", parse_body(raw)) && occursin("\"page\":3", parse_body(raw)))

raw = http_get("/calc/add/1.5/2.25")
check("Typed Float64 params → parse and compute",
    parse_status(raw) == 200 && occursin("\"sum\":3.75", parse_body(raw)))

# ── Context ──────────────────────────────────────────

raw = http_get("/context")
check("context! → per-request Dict",
    parse_status(raw) == 200 && occursin("\"context\":\"trim-safe binary\"", parse_body(raw)))

# ── Custom response headers ──────────────────────────

raw = http_get("/custom-headers")
check("Custom headers → X-Custom-Header present",
    parse_status(raw) == 200 &&
    parse_header(raw, "X-Custom-Header") == "mongoose" &&
    parse_header(raw, "X-Powered-By") == "Mongoose.jl")

# ── fail! (custom 500) ──────────────────────────────

raw = http_get("/error")
body = parse_body(raw)
check("fail! custom 500 → JSON error body",
    parse_status(raw) == 500 && occursin("\"error\":\"internal server error\"", body))

# ── Wildcard catch-all 404 ───────────────────────────

raw = http_get("/nonexistent/deep/path")
check("Wildcard /*path → 404 JSON + path",
    parse_status(raw) == 404 && occursin("\"path\":\"nonexistent/deep/path\"", parse_body(raw)))

# ── mount! static files ─────────────────────────────

raw = http_get("/static/test.txt")
check("mount! static → test.txt served",
    parse_status(raw) == 200 && occursin("hello from static file serving", parse_body(raw)))

raw = http_get("/static/index.html")
check("mount! static → index.html served",
    parse_status(raw) == 200 && occursin("Static Index", parse_body(raw)))

raw = http_get("/static/test.txt"; headers=["Range" => "bytes=0-4"])
check("mount! static → Range request returns 206",
    parse_status(raw) == 206 && parse_body(raw) == "hello")

raw = http_get("/static/test.txt")
etag = parse_header(raw, "ETag")
check("mount! static → ETag present",
    etag !== nothing && !isempty(etag))

if etag !== nothing && !isempty(etag)
    raw = http_get("/static/test.txt"; headers=["If-None-Match" => etag])
    check("mount! static → If-None-Match returns 304",
        parse_status(raw) == 304)
else
    check("mount! static → If-None-Match returns 304", false; detail="ETag header missing from initial static response")
end

# ── X-Request-Id header ─────────────────────────────
println("│")
printstyled("│  ── Infrastructure ──\n"; color=:cyan)

raw = http_get("/hello")
rid = parse_header(raw, "X-Request-Id")
check("X-Request-Id → auto-generated",
    rid !== nothing && !isempty(rid))

# Echo back a supplied request ID
raw = http_get("/hello"; headers=["X-Request-Id" => "trace-abc-123"])
rid = parse_header(raw, "X-Request-Id")
check("X-Request-Id → echo-back supplied ID",
    rid == "trace-abc-123")

# ── WebSocket lifecycle ─────────────────────────────
println("│")
printstyled("│  ── WebSocket ──\n"; color=:cyan)

ws_client_ref = Ref{Union{Nothing,WsClient}}(nothing)
try
    ws_client_ref[] = ws_open("/ws/chat"; headers=["X-Chat-Auth" => "trim-safe"])
    check("WS /ws/chat → 101 upgrade", true)

    ws_send_text(ws_client_ref[]::WsClient, "hello")
    opcode, payload = ws_receive_frame(ws_client_ref[]::WsClient)
    check("WS text echo → Message(String)",
        opcode == WS_TEXT && String(payload) == "echo:text:hello")

    ws_send_binary(ws_client_ref[]::WsClient, UInt8[0x10, 0x20, 0x30])
    opcode, payload = ws_receive_frame(ws_client_ref[]::WsClient)
    check("WS binary echo → Message(Vector{UInt8})",
        opcode == WS_BINARY && payload == UInt8[0x42, 0x10, 0x20, 0x30])

    ws_send_frame(ws_client_ref[]::WsClient, WS_PING, UInt8[0xaa, 0xbb])
    opcode, payload = ws_receive_frame(ws_client_ref[]::WsClient)
    check("WS ping → automatic pong",
        opcode == WS_PONG && payload == UInt8[0xaa, 0xbb])
catch e
    check("WS /ws/chat → 101 upgrade", false; detail=sprint(showerror, e))
finally
    ws_client_ref[] !== nothing && ws_close(ws_client_ref[]::WsClient)
end

sleep(0.2)
raw = http_get("/ws/state")
body = parse_body(raw)
check("WS lifecycle callbacks → open/close tracked",
    parse_status(raw) == 200 &&
    occursin("\"opened\":1", body) &&
    occursin("\"closed\":1", body) &&
    occursin("\"last_auth\":\"trim-safe\"", body))

reject_headers = [
    "Upgrade" => "websocket",
    "Connection" => "Upgrade",
    "Sec-WebSocket-Key" => base64encode(rand(UInt8, 16)),
    "Sec-WebSocket-Version" => "13",
]
raw = http_get("/ws/reject"; headers=reject_headers)
check("WS /ws/reject → 403 from on_open=false",
    parse_status(raw) == 403)

# ── Cleanup ──────────────────────────────────────────

println("│")
println("├─ Stopping binary …")
kill(proc)
try wait(proc) catch end

# ── Report ───────────────────────────────────────────

total = passed + failed
println("└─ Results: $passed/$total passed")
if failed > 0
    printstyled("   FAILED ($failed failures)\n"; color=:red, bold=true)
    exit(1)
else
    printstyled("   ALL PASSED ✓\n"; color=:green, bold=true)
end
