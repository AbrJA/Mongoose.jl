using Mongoose

# ────────────────────────────────────────────────────
# Comprehensive juliac --trim=safe example.
#
# Exercises: @router (all HTTP methods, typed/wildcard params),
#            mount!, fail!, context!, query(), Response formats,
#            custom headers, binary body, WebSocket, HEAD auto-handler.
# ────────────────────────────────────────────────────

# --- Query struct for typed parsing ---
struct SearchQuery
    q::String
    page::Int
end

# --- Handlers ---

function greet(req)
    Response(Json, "{\"message\":\"Hello World from trimmed Julia!\"}")
end

function echo_name(req, name)
    Response(Plain, "Hello " * String(name) * "!")
end

function user_by_id(req, id)
    Response(Json, "{\"id\":" * string(id) * ",\"name\":\"user_" * string(id) * "\"}")
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
    params = query(SearchQuery, req)::SearchQuery
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

function xml_response(req)
    Response(Xml, "<root><status>ok</status></root>")
end

function html_page(req)
    Response(Html, "<html><body><h1>Mongoose.jl</h1><p>Static binary HTML response</p></body></html>")
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

function trigger_error(req)
    error("Intentional 500 test")
end

function not_found_handler(req, path)
    Response(Json, "{\"error\":\"not found\",\"path\":\"" * String(path) * "\"}"; status=404)
end

# --- Static Router ---

@router Routes begin
    # Basic GET
    get("/",                  html_page)
    get("/hello",             greet)
    get("/health",            health)

    # All response formats
    get("/format/json",       req -> Response(Json, "{\"format\":\"json\"}"))
    get("/format/html",       html_page)
    get("/format/xml",        xml_response)
    get("/format/css",        css_response)
    get("/format/js",         js_response)
    get("/format/binary",     binary_response)

    # Typed and string params
    get("/echo/:name",         echo_name)
    get("/user/:id::Int",      user_by_id)

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
#   curl http://localhost:8099/format/xml
#   curl http://localhost:8099/error
#   curl http://localhost:8099/static/test.txt
#   curl http://localhost:8099/nonexistent
