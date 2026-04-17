using Mongoose

# ────────────────────────────────────────────────────
# Comprehensive juliac --trim=safe example.
#
# Exercises: @router (all HTTP methods, typed/wildcard params),
#            mount!, fail!, context!, query(), Response formats,
#            custom headers, binary body, WebSocket lifecycle,
#            upgrade rejection, HEAD auto-handler.
# ────────────────────────────────────────────────────

# --- Query struct for typed parsing ---
struct SearchQuery
    q::String
    page::Int
end

# --- In-memory user store (trim-safe compatible, concrete types only) ---
mutable struct User
    id::Int
    name::String
    email::String
    role::String
end

@inline function _json_get_string(body::String, key::String, default::String)::String
    needle = "\"" * key * "\""
    r = findfirst(needle, body)
    r === nothing && return default

    i = last(r) + 1
    n = ncodeunits(body)

    while i <= n
        c = codeunit(body, i)
        if c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\r') || c == UInt8('\n') || c == UInt8(':')
            i += 1
        else
            break
        end
    end

    i > n && return default
    codeunit(body, i) == UInt8('"') || return default
    i += 1
    start_i = i

    while i <= n && codeunit(body, i) != UInt8('"')
        i += 1
    end

    i > n && return default
    return String(view(body, start_i:i-1))
end

@inline function _query_get_string(query::AbstractString, key::String, default::String)::String
    q = String(query)
    isempty(q) && return default
    prefix = key * "="
    for pair in split(q, '&')
        startswith(pair, prefix) || continue
        return String(view(pair, ncodeunits(prefix)+1:ncodeunits(pair)))
    end
    return default
end

@inline function _user_json(u::User)::String
    return "{\"id\":" * string(u.id) *
           ",\"name\":\"" * u.name * "\"" *
           ",\"email\":\"" * u.email * "\"" *
           ",\"role\":\"" * u.role * "\"}"
end

const USERS = Ref(Dict(
    1 => User(1, "Alice", "alice@example.com", "admin"),
    2 => User(2, "Bob", "bob@example.com", "user"),
    3 => User(3, "Charlie", "charlie@example.com", "user"),
))
const NEXT_ID = Ref(4)

const WS_OPEN_COUNT = Ref(0)
const WS_CLOSE_COUNT = Ref(0)
const WS_LAST_AUTH = Ref("none")

# --- Handlers ---

# --- CRUD Handlers ---

function users_list(req)
    users = USERS[]
    json_items = String[]
    for (_, user) in users
        push!(json_items, _user_json(user))
    end
    body = "[" * join(json_items, ",") * "]"
    Response(Json, body)
end

function user_detail(req, id)
    users = USERS[]
    if !haskey(users, id)
        return Response(Json, "{\"error\":\"user not found\"}";
            status=404)
    end
    Response(Json, _user_json(users[id]))
end

function user_create(req)
    users = USERS[]
    id = NEXT_ID[]
    NEXT_ID[] += 1
    name = _json_get_string(req.body, "name", "NewUser")
    email = _json_get_string(req.body, "email", "new@example.com")
    role = _json_get_string(req.body, "role", "user")
    new_user = User(id, name, email, role)
    users[id] = new_user
    Response(Json, _user_json(new_user); status=201)
end

function user_update(req, id)
    users = USERS[]
    if !haskey(users, id)
        return Response(Json, "{\"error\":\"user not found\"}";
            status=404)
    end
    user = users[id]
    user.name = _json_get_string(req.body, "name", user.name)
    user.email = _json_get_string(req.body, "email", user.email)
    user.role = _json_get_string(req.body, "role", user.role)
    Response(Json, _user_json(user))
end

function user_delete(req, id)
    users = USERS[]
    if !haskey(users, id)
        return Response(Json, "{\"error\":\"user not found\"}";
            status=404)
    end
    delete!(users, id)
    Response(204, "", "")
end

function serve_test_dashboard(req)
    html = read(joinpath(@__DIR__, "public", "test.html"), String)
    Response(Html, html)
end

# --- Other Handlers ---
function greet(req)
    Response(Json, "{\"message\":\"Hello World from trimmed Julia!\"}")
end

function echo_name(req, name)
    Response(Plain, "Hello " * String(name) * "!")
end

function user_by_id(req, id)
    Response(Json, "{\"id\":" * string(id) * ",\"name\":\"user_" * string(id) * "\"}")
end

function add_numbers(req, a, b)
    Response(Json,
        "{\"a\":" * string(a) * ",\"b\":" * string(b) * ",\"sum\":" * string(a + b) * "}")
end

function create_item(req)
    # POST — echo back the body wrapped in a JSON envelope
    Response(Json, "{\"received\":" * req.body * "}"; status=201)
end

function update_item(req, id)
    # PUT — full update
    Response(Json, "{\"updated\":" * string(id) * ",\"body\":" * req.body * "}")
end

function patch_item(req, id)
    # PATCH — partial update
    Response(Json, "{\"patched\":" * string(id) * "}")
end

function delete_item(req, id)
    # DELETE — return 204 No Content
    Response(204, "", "")
end

function search(req)
    # Query string parsing into a typed struct
    params = Mongoose.query(SearchQuery, req)::SearchQuery
    Response(Json, "{\"q\":\"" * params.q * "\",\"page\":" * string(params.page) * "}")
end

function with_context(req)
    # context! — lazily created per-request Dict
    ctx = context!(req)
    ctx[:handled_by] = "trim-safe binary"
    val = ctx[:handled_by]::String
    Response(Json, "{\"context\":\"" * val * "\"}")
end

function custom_headers(req)
    # Response with extra custom headers
    Response(Json, "{\"custom\":true}";
        headers=["X-Custom-Header" => "mongoose", "X-Powered-By" => "Mongoose.jl"])
end

function binary_response(req)
    # Binary body (Vector{UInt8}) — uses mg_send path
    data = UInt8[0x89, 0x50, 0x4E, 0x47]  # PNG magic bytes stub
    Response(200, "Content-Type: application/octet-stream\r\n", data)
end

function typed_binary_response(req)
    Response(Binary, UInt8[0x01, 0x02, 0x03, 0x04])
end

function xml_response(req)
    Response(Xml, "<root><status>ok</status></root>")
end

function html_page(req)
    Response(Html, "<html><body><h1>Mongoose.jl</h1><p>Static binary HTML response</p></body></html>")
end

function plain_page(req)
    Response("plain response body")
end

function css_response(req)
    Response(Css, "body { color: green; }")
end

function js_response(req)
    Response(Js, "console.log('hello from trim-safe binary');")
end

function health(req)
    Response(Json, "{\"status\":\"ok\"}")
end

function head_probe(req)
    Response(Plain, "head-body"; headers=["X-Head-Check" => "yes"])
end

function trigger_error(req)
    error("Intentional 500 test")
end

function ws_state(req)
    Response(Json,
        "{\"opened\":" * string(WS_OPEN_COUNT[]) *
        ",\"closed\":" * string(WS_CLOSE_COUNT[]) *
        ",\"last_auth\":\"" * WS_LAST_AUTH[] * "\"}")
end

function ws_chat_open(req)
    WS_OPEN_COUNT[] += 1
    h_auth = get(req.headers, "x-chat-auth", "")
    WS_LAST_AUTH[] = isempty(h_auth) ? _query_get_string(req.query, "auth", "none") : h_auth
    return true
end

function ws_chat_message(msg::Message)
    if msg.data isa String
        return Message("echo:text:" * msg.data)
    end
    data = msg.data::Vector{UInt8}
    reply = UInt8[0x42]
    append!(reply, data)
    return Message(reply)
end

function ws_chat_close()
    WS_CLOSE_COUNT[] += 1
    return nothing
end

ws_reject_open(req) = false

function not_found_handler(req, path)
    Response(Json, "{\"error\":\"not found\",\"path\":\"" * String(path) * "\"}"; status=404)
end

# --- Static Router ---

@router Routes begin
    # Basic GET
    get("/",                  serve_test_dashboard)
    get("/hello",             greet)
    get("/health",            health)
    get("/head-probe",        head_probe)
    get("/ws/state",          ws_state)

    # All response formats
    get("/format/plain",      plain_page)
    get("/format/json",       req -> Response(Json, "{\"format\":\"json\"}"))
    get("/format/html",       html_page)
    get("/format/xml",        xml_response)
    get("/format/css",        css_response)
    get("/format/js",         js_response)
    get("/format/binary",     binary_response)
    get("/format/binary/typed", typed_binary_response)

    # Typed and string params
    get("/echo/:name",         echo_name)
    get("/user/:id::Int",      user_by_id)
    get("/calc/add/:a::Float64/:b::Float64", add_numbers)

    # All HTTP methods (CRUD)
    post("/items",             create_item)
    put("/items/:id::Int",     update_item)
    patch("/items/:id::Int",   patch_item)
    delete("/items/:id::Int",  delete_item)

    # Query parsing
    get("/search",            search)

    # Context
    get("/context",           with_context)

    # Custom headers
    get("/custom-headers",    custom_headers)

    # Error (for fail! testing)
    get("/error",             trigger_error)

    # WebSocket endpoints
    ws("/ws/chat", on_message=ws_chat_message, on_open=ws_chat_open, on_close=ws_chat_close)
    ws("/ws/reject", on_message=ws_chat_message, on_open=ws_reject_open)

    # CRUD Users API
    get("/api/users",              users_list)
    get("/api/users/:id::Int",     user_detail)
    post("/api/users",             user_create)
    put("/api/users/:id::Int",     user_update)
    delete("/api/users/:id::Int",  user_delete)

    # Wildcard catch-all (must be last)
    get("/*path",             not_found_handler)
end

# --- Entry point ---

(@main)(ARGS) = begin
    server = Server(Routes)

    # Custom error responses via fail!
    fail!(server, 500, Response(Json, "{\"error\":\"internal server error\"}"; status=500))
    fail!(server, 413, Response(Json, "{\"error\":\"payload too large\"}"; status=413))

    # Static file serving via mount!
    public_dir = joinpath(@__DIR__, "public")
    if isdir(public_dir)
        mount!(server, public_dir; uri_prefix="/static")
    end

    start!(server, port=8099, blocking=true)
    return 0
end

# Build:
#   juliac --trim=safe --project . --output-exe binary example/juliac/server.jl
#
# Run:
#   ./binary
#
# Test:
#   curl http://localhost:8099/hello
#   curl http://localhost:8099/echo/World
#   curl http://localhost:8099/user/42
#   curl -X POST -d '{"name":"test"}' http://localhost:8099/items
#   curl -X PUT  -d '{"name":"new"}'  http://localhost:8099/items/1
#   curl -X PATCH   http://localhost:8099/items/1
#   curl -X DELETE  http://localhost:8099/items/1
#   curl "http://localhost:8099/search?q=hello&page=2"
#   curl http://localhost:8099/context
#   curl http://localhost:8099/custom-headers -v
#   curl http://localhost:8099/head-probe -I
#   curl http://localhost:8099/format/xml
#   curl http://localhost:8099/format/binary/typed --output - | hexdump -C
#   curl http://localhost:8099/calc/add/1.5/2.25
#   curl http://localhost:8099/error
#   curl http://localhost:8099/static/test.txt
#   curl http://localhost:8099/nonexistent
#   websocat -H='X-Chat-Auth: trim-safe' ws://localhost:8099/ws/chat
