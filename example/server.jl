"""
Mongoose.jl Example Server

Demonstrates every framework feature:
  - CRUD REST with typed URL params (:id::Int, :name::String)
  - PATCH for partial updates
  - Wildcard * route (custom 404)
  - Typed query struct deserialization (Mongoose.query)
  - request context! for middleware→handler data passing
  - Binary responses (generated PNG, CSV download, protected files)
  - WebSocket with on_open / on_message / on_close
  - All built-in middleware: cors, logger (plain + threshold), rate_limit,
    health (custom callbacks), metrics (Prometheus), api_key, bearer_token
  - Custom middleware (InjectUser) to demonstrate AbstractMiddleware + context!
  - Path-scoped middleware with paths=[...]
  - Custom error responses (500 / 413 / 504)
  - C-level static file serving via mount!
  - render_body extension for arbitrary serialisation

    julia --project example/server.jl
    open http://localhost:9000
"""

using Mongoose
using JSON
using Dates

# ── render_body extension ──────────────────────────────────────────────────────
# Extend Mongoose to serialise any Julia value to JSON via the JSON package.
Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

# ── In-memory user store ───────────────────────────────────────────────────────
const LOCK    = ReentrantLock()
const USERS   = Dict{Int,Dict{String,Any}}(
    1 => Dict("id"=>1,"name"=>"Alice",  "email"=>"alice@example.com",  "role"=>"admin", "active"=>true),
    2 => Dict("id"=>2,"name"=>"Bob",    "email"=>"bob@example.com",    "role"=>"user",  "active"=>true),
    3 => Dict("id"=>3,"name"=>"Charlie","email"=>"charlie@example.com","role"=>"user",  "active"=>false),
)
const NEXT_ID = Ref(4)

# ── Server state (used by health check callbacks) ──────────────────────────────
const START_TIME = time()
const WS_COUNT   = Ref(0)

# Simulated database connection flag — toggle via PUT /admin/db/down|up
# to exercise health check failures without restarting the server.
const DB_ONLINE = Ref(true)

# ── Typed query param structs ──────────────────────────────────────────────────
struct UserFilter
    role::String
    limit::Union{Int,Nothing}
    active::Union{Bool,Nothing}   # ?active=true|false — Bool query field
end

struct ImageParams
    r::Union{Int,Nothing}   # default 128
    g::Union{Int,Nothing}   # default 64
    b::Union{Int,Nothing}   # default 200
end

struct DebugSlowParams
    ms::Union{Int,Nothing}   # sleep duration; >3000 triggers 504
end

struct DebugFormatParams
    type::String   # html | xml | css | js | binary | plain (default)
end

# 8×8 solid-colour PNG, no external dependencies.
function _make_png(r::UInt8, g::UInt8, b::UInt8)::Vector{UInt8}
    w, h = 8, 8
    # Filter type 0 (None) scanline: one 0x00 byte then w RGB pixels per row.
    raw = UInt8[]
    for _ in 1:h
        push!(raw, 0x00)
        for _ in 1:w; push!(raw, r, g, b) end
    end
    idat_data = _zlib_compress(raw)

    function chunk(tag::String, data::Vector{UInt8})
        len = length(data)
        crc = _crc32([codeunits(tag); data])
        [
            UInt8((len >> 24) & 0xff), UInt8((len >> 16) & 0xff),
            UInt8((len >>  8) & 0xff), UInt8( len        & 0xff),
            codeunits(tag)..., data...,
            UInt8((crc >> 24) & 0xff), UInt8((crc >> 16) & 0xff),
            UInt8((crc >>  8) & 0xff), UInt8( crc        & 0xff),
        ]
    end

    ihdr = UInt8[
        0,0,0,w, 0,0,0,h,  # width, height (big-endian uint32)
        8, 2,              # bit depth, colour type RGB
        0, 0, 0,           # compression, filter, interlace
    ]

    out = UInt8[
        0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,  # PNG signature (RFC 2083)
        chunk("IHDR", ihdr)...,
        chunk("IDAT", idat_data)...,
        chunk("IEND", UInt8[])...,
    ]
    return out
end

# zlib with deflate stored blocks (no compression). CMF=0x78, FLG=0x01 satisfies
# the zlib header check: (CMF*256 + FLG) % 31 == 0.
function _zlib_compress(data::Vector{UInt8})::Vector{UInt8}
    out = UInt8[0x78, 0x01]
    i = 1
    while i <= length(data)
        block = data[i:min(i+65534, end)]
        last  = (i + length(block) - 1) >= length(data)
        blen  = length(block)
        push!(out, last ? 0x01 : 0x00)               # BFINAL | BTYPE=00 (stored)
        push!(out, blen & 0xff, (blen >> 8) & 0xff)   # LEN
        push!(out, (~blen) & 0xff, ((~blen) >> 8) & 0xff) # NLEN (one's complement)
        append!(out, block)
        i += blen
    end
    # Adler-32 trailer required by zlib (RFC 1950)
    s1, s2 = UInt32(1), UInt32(0)
    for b in data
        s1 = (s1 + b)    % 65521
        s2 = (s2 + s1)   % 65521
    end
    adler = (s2 << 16) | s1
    push!(out,
        UInt8((adler >> 24) & 0xff), UInt8((adler >> 16) & 0xff),
        UInt8((adler >>  8) & 0xff), UInt8( adler        & 0xff))
    return out
end

# CRC-32 (PNG chunk integrity)
const _CRC_TABLE = let t = Vector{UInt32}(undef, 256)
    for n in 0:255
        c = UInt32(n)
        for _ in 1:8
            c = (c & 1) != 0 ? (0xedb88320 ⊻ (c >> 1)) : (c >> 1)
        end
        t[n+1] = c
    end
    t
end
function _crc32(data)::UInt32
    c = ~UInt32(0)
    for b in data
        c = _CRC_TABLE[((c ⊻ b) & 0xff) + 1] ⊻ (c >> 8)
    end
    return ~c
end

function handle_ping(req::Request)
    Response(Json, Dict(
        "pong"     => true,
        "time"     => string(now(UTC)),
        "uptime_s" => round(time() - START_TIME, digits=1),
    ))
end

function handle_list_users(req::Request)
    # Demonstrates Mongoose.query — typed query-string deserialization
    f = Mongoose.query(UserFilter, req)

    users = lock(LOCK) do
        collect(values(USERS))
    end

    isempty(f.role)      || filter!(u -> u["role"]   == f.role,        users)
    f.active !== nothing && filter!(u -> u["active"] == f.active,       users)
    f.limit !== nothing  && (users = first(users, min(f.limit, length(users))))
    sort!(users; by = u -> u["id"])

    Response(Json, Dict("users" => users, "count" => length(users)))
end

function handle_get_user(req::Request, id::Int)
    user = lock(LOCK) do; get(USERS, id, nothing) end
    user === nothing && return Response(Json, Dict("error"=>"User $id not found"); status=404)
    Response(Json, user)
end

function handle_create_user(req::Request)
    isempty(req.body) && return Response(Json, Dict("error"=>"Empty body"); status=400)
    body = try JSON.parse(req.body) catch; return Response(Json, Dict("error"=>"Invalid JSON"); status=400) end

    haskey(body,"name")  || return Response(Json, Dict("error"=>"Missing: name");  status=422)
    haskey(body,"email") || return Response(Json, Dict("error"=>"Missing: email"); status=422)

    user = lock(LOCK) do
        id = NEXT_ID[]; NEXT_ID[] += 1
        u = Dict{String,Any}("id"=>id,"name"=>body["name"],"email"=>body["email"],"role"=>get(body,"role","user"))
        USERS[id] = u; u
    end
    Response(Json, user; status=201)
end

# PATCH — partial update: only fields present in the request body are changed.
function handle_patch_user(req::Request, id::Int)
    isempty(req.body) && return Response(Json, Dict("error"=>"Empty body"); status=400)
    body = try JSON.parse(req.body) catch; return Response(Json, Dict("error"=>"Invalid JSON"); status=400) end
    updated = lock(LOCK) do
        u = get(USERS, id, nothing)
        u === nothing && return nothing
        for (k, v) in body; k == "id" && continue; u[k] = v end
        u
    end
    updated === nothing && return Response(Json, Dict("error"=>"User $id not found"); status=404)
    Response(Json, updated)
end

# PUT — full replacement (all fields required)
function handle_update_user(req::Request, id::Int)
    body = try JSON.parse(req.body) catch; return Response(Json, Dict("error"=>"Invalid JSON"); status=400) end
    updated = lock(LOCK) do
        u = get(USERS, id, nothing)
        u === nothing && return nothing
        for (k, v) in body; k == "id" && continue; u[k] = v end
        u
    end
    updated === nothing && return Response(Json, Dict("error"=>"User $id not found"); status=404)
    Response(Json, updated)
end

function handle_delete_user(req::Request, id::Int)
    d = lock(LOCK) do; pop!(USERS, id, nothing) end
    d === nothing && return Response(Json, Dict("error"=>"User $id not found"); status=404)
    Response(Json, Dict("deleted"=>true, "id"=>id))
end

# Wildcard catch-all — custom 404 for any unmatched GET.
function handle_not_found(req::Request)
    Response(Json, Dict("error"=>"Not Found", "uri"=>req.uri); status=404)
end

function handle_image(req::Request)
    p   = Mongoose.query(ImageParams, req)
    r   = UInt8(clamp(something(p.r, 128), 0, 255))
    g   = UInt8(clamp(something(p.g,  64), 0, 255))
    b   = UInt8(clamp(something(p.b, 200), 0, 255))
    png = _make_png(r, g, b)
    Response(200, "Content-Type: image/png\r\nCache-Control: no-cache\r\n", png)
end

function handle_download(req::Request)
    users = lock(LOCK) do; collect(values(USERS)) end
    sort!(users; by = u -> u["id"])
    csv = "id,name,email,role\n" *
          join(["$(u["id"]),$(u["name"]),$(u["email"]),$(u["role"])" for u in users], "\n") * "\n"
    Response(200,
        "Content-Type: text/csv\r\n" *
        "Content-Disposition: attachment; filename=\"users.csv\"\r\n",
        csv)
end

# mount! runs at the C level before middleware, so it cannot enforce auth.
# These routes read files into Vector{UInt8} inside the middleware pipeline,
# where api_key middleware has already verified credentials.
const PROTECTED_MIME = Dict(
    ".png"  => "image/png",
    ".jpg"  => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif"  => "image/gif",
    ".webp" => "image/webp",
    ".pdf"  => "application/pdf",
    ".csv"  => "text/csv",
    ".txt"  => "text/plain",
)
const PROTECTED_DIR = joinpath(@__DIR__, "public", "assets")

function handle_protected_list(req::Request)
    files = isdir(PROTECTED_DIR) ? readdir(PROTECTED_DIR) : String[]
    filter!(f -> haskey(PROTECTED_MIME, lowercase(splitext(f)[2])), files)
    Response(Json, Dict("files" => files))
end

function handle_protected_file(req::Request, name::String)
    # Reject path separators to prevent directory traversal.
    (occursin('/', name) || occursin('\\', name)) &&
        return Response(Json, Dict("error" => "Invalid filename"); status=400)

    path = joinpath(PROTECTED_DIR, name)
    isfile(path) || return Response(Json, Dict("error" => "Not found: $name"); status=404)

    ext  = lowercase(splitext(name)[2])
    mime = get(PROTECTED_MIME, ext, "application/octet-stream")
    data = read(path)

    force_dl = occursin("download=true", req.query) || occursin("download=1", req.query)
    disp = force_dl ? "attachment" :
           startswith(mime, "image/") || mime == "application/pdf" ? "inline" : "attachment"

    Response(200,
        "Content-Type: $mime\r\n" *
        "Content-Disposition: $disp; filename=\"$name\"\r\n",
        data)
end

# ── Admin handlers ─────────────────────────────────────────────────────────────

# Demonstrates context!(req): reads user info injected by InjectUser middleware.
function handle_whoami(req::Request)
    ctx = Mongoose.context!(req)
    Response(Json, Dict(
        "user_id" => get(ctx, :user_id, nothing),
        "role"    => get(ctx, :role,    nothing),
    ))
end

# Toggle the simulated DB flag to exercise /healthz failures in a live server.
function handle_db_toggle(req::Request, state::String)
    if state == "up"
        DB_ONLINE[] = true
    elseif state == "down"
        DB_ONLINE[] = false
    else
        return Response(Json, Dict("error"=>"state must be 'up' or 'down'"); status=400)
    end
    Response(Json, Dict("db_online" => DB_ONLINE[]))
end

# ── Debug handlers ────────────────────────────────────────────────────────────

# Reflects every parsed detail back as JSON — invaluable for spotting parsing bugs.
function handle_debug_echo(req::Request)
    Response(Json, Dict(
        "method"  => string(req.method),
        "uri"     => req.uri,
        "query"   => req.query,
        "headers" => Dict(k => v for (k, v) in req.headers),
        "body"    => req.body,
    ))
end

# Intentional error — exercises the custom 500 fail!.
function handle_debug_panic(req::Request)
    error("Intentional panic from /debug/panic — confirms custom 500 response is working")
end

# Sleep for ?ms=N milliseconds.
# ms=600  → triggers the logger(threshold=500) line in stderr.
# ms=4000 → exceeds request_timeout=3000 and returns the custom 504 response.
function handle_debug_slow(req::Request)
    p  = Mongoose.query(DebugSlowParams, req)
    ms = clamp(something(p.ms, 100), 0, 10_000)
    sleep(ms / 1000)
    Response(Json, Dict("slept_ms" => ms))
end

# Returns a response using each Mongoose format type.
# ?type=html|xml|css|js|binary|plain  (default: plain)
function handle_debug_formats(req::Request)
    p = Mongoose.query(DebugFormatParams, req)
    t = lowercase(p.type)
    t == "html"   && return Response(Html,   "<h1>Hello from <code>Html</code></h1>")
    t == "xml"    && return Response(Xml,    """<?xml version=\"1.0\"?><message>Hello from Xml</message>""")
    t == "css"    && return Response(Css,    "body { font-family: monospace; color: navy; }")
    t == "js"     && return Response(Js,     "console.log('Hello from Js format type');")
    t == "binary" && return Response(Binary, UInt8[0x4d, 0x6f, 0x6f, 0x73, 0x65])  # "Moose"
    Response(Plain, "Hello from Plain (default format type)")
end

# Trivial handler — a tight scoped rate limit (3 req/30 s) is attached below.
# Hit it 4+ times quickly to get a 429 with Retry-After.
function handle_debug_limited(req::Request)
    Response(Json, Dict("ok" => true, "tip" => "Hit this 4+ times in 30s to trigger 429"))
end

# Float64 typed URL params: GET /api/calc/add/1.5/2.3  →  {result: 3.8}
function handle_calc(req::Request, op::String, a::Float64, b::Float64)
    result = if op == "add"
        a + b
    elseif op == "sub"
        a - b
    elseif op == "mul"
        a * b
    elseif op == "div"
        b == 0.0 && return Response(Json, Dict("error" => "Division by zero"); status=400)
        a / b
    else
        return Response(Json, Dict("error" => "op must be add|sub|mul|div"); status=400)
    end
    Response(Json, Dict("op" => op, "a" => a, "b" => b, "result" => result))
end

function ws_open(req::Request)
    WS_COUNT[] += 1
    @info "WS connected" uri=req.uri active=WS_COUNT[]
end

function ws_message(msg::Message)
    text = msg.data isa String ? msg.data : "[binary: $(length(msg.data)) bytes]"
    @info "WS message" data=text
    ts = Dates.format(now(UTC), "HH:MM:SS")
    Message("[$ts] Echo: $text")
end

function ws_close()
    WS_COUNT[] = max(0, WS_COUNT[] - 1)
    @info "WS disconnected" active=WS_COUNT[]
end

# ── Custom middleware: InjectUser ──────────────────────────────────────────────
# Demonstrates AbstractMiddleware and context!(req).
# Validates an Authorization: Bearer token and injects the associated user info
# into the request context, making it available to downstream handlers via
# Mongoose.context!(req)[:user_id] and [:role].
struct InjectUser <: Mongoose.AbstractMiddleware
    tokens::Dict{String, Dict{Symbol,Any}}
end

function (mw::InjectUser)(req::Mongoose.AbstractRequest, params::Vector{Any}, next)
    auth = get(req.headers, "authorization", "")
    if length(auth) > 7 && lowercase(auth[1:7]) == "bearer "
        token = strip(auth[8:end])
        user  = get(mw.tokens, token, nothing)
        if user !== nothing
            merge!(Mongoose.context!(req), user)
            return next()
        end
    end
    Response(Plain, "401 Unauthorized"; status=401,
        headers=["WWW-Authenticate" => "Bearer realm=\"admin\""])
end

# ── Build & start ──────────────────────────────────────────────────────────────
function main()
    router = Router()

    # ── REST routes ────────────────────────────────────────────────────────────
    route!(router, :get,    "/api/ping",                  handle_ping)
    route!(router, :get,    "/api/users",                 handle_list_users)
    route!(router, :get,    "/api/users/:id::Int",        handle_get_user)
    route!(router, :post,   "/api/users",                 handle_create_user)
    route!(router, :patch,  "/api/users/:id::Int",        handle_patch_user)
    route!(router, :put,    "/api/users/:id::Int",        handle_update_user)
    route!(router, :delete, "/api/users/:id::Int",        handle_delete_user)

    # ── Binary / file responses ────────────────────────────────────────────────
    route!(router, :get, "/api/image",                    handle_image)
    route!(router, :get, "/api/protected",                handle_protected_list)
    route!(router, :get, "/api/protected/:name::String",  handle_protected_file)
    route!(router, :get, "/api/download",                 handle_download)

    # ── Admin (bearer-token protected via InjectUser middleware) ───────────────
    route!(router, :get, "/admin/whoami",                 handle_whoami)
    route!(router, :put, "/admin/db/:state::String",      handle_db_toggle)

    # ── Math — Float64 typed URL params ───────────────────────────────────────
    # e.g. GET /api/calc/add/1.5/2.3  →  {"op":"add","a":1.5,"b":2.3,"result":3.8}
    route!(router, :get, "/api/calc/:op::String/:a::Float64/:b::Float64", handle_calc)

    # ── Debug endpoints (no auth required) ────────────────────────────────────
    route!(router, :get,  "/debug/echo",    handle_debug_echo)   # see what server parsed
    route!(router, :post, "/debug/echo",    handle_debug_echo)   # POST to include a body
    route!(router, :get,  "/debug/panic",   handle_debug_panic)  # trigger custom 500
    route!(router, :get,  "/debug/slow",    handle_debug_slow)   # ?ms=N  (4000 → 504)
    route!(router, :get,  "/debug/formats", handle_debug_formats) # ?type=html|xml|css|js|binary|plain
    route!(router, :get,  "/debug/limited", handle_debug_limited) # 3 req/30s rate limit

    # ── WebSocket ──────────────────────────────────────────────────────────────
    ws!(router, "/ws/chat";
        on_open    = ws_open,
        on_message = ws_message,
        on_close   = ws_close,
    )

    # ── Wildcard catch-all — custom 404 for any unmatched route ───────────────
    route!(router, :get, "*", handle_not_found)

    # ── Server ─────────────────────────────────────────────────────────────────
    # request_timeout=3_000 ms so /debug/slow?ms=4000 triggers the 504 in ~3 s.
    server = AsyncServer(router; workers=4, nqueue=2048, request_timeout=3_000)

    # ── Middleware (executed in FIFO order) ────────────────────────────────────

    # 1. CORS — must run first so preflight OPTIONS replies carry the right headers.
    plug!(server, cors(
        origins = "*",
        methods = "GET, POST, PUT, PATCH, DELETE, OPTIONS",
        headers = "Content-Type, Authorization, X-API-Key",
    ))

    # 2. Request logging (structured JSON).
    plug!(server, logger(structured=true))

    # 3. Slow-request logger — only emits a line when the request takes > 500ms.
    plug!(server, logger(threshold=500))

    # 4. Rate limiter — 300 req / 60 s per client IP.
    plug!(server, rate_limit(max_requests=300, window_seconds=60))

    # 5. Health checks with custom callbacks.
    #    DB_ONLINE is toggled via PUT /admin/db/down|up to simulate failures.
    plug!(server, health(
        health_check = () -> DB_ONLINE[],
        ready_check  = () -> DB_ONLINE[],
        live_check   = () -> true,          # process is always alive if running
    ))

    # 6. Prometheus metrics — exposes GET /metrics automatically.
    #    Tracks http_requests_total{method,status} and
    #    http_request_duration_seconds histogram across all shards.
    plug!(server, metrics())

    # 7. API-key auth, scoped to /api/* only.
    valid_api_keys = Set(["demo-key-1234", "prod-key-secret"])
    plug!(server, api_key(keys=valid_api_keys); paths=["/api"])

    # 9. Tight scoped rate limit on /debug/limited — hit it 4+ times in 30s to get 429.
    plug!(server, rate_limit(max_requests=3, window_seconds=30); paths=["/debug/limited"])

    # 8. Bearer-token auth for /admin/*, also injects user info into context!.
    #    Handlers read Mongoose.context!(req)[:user_id] and [:role].
    admin_tokens = Dict{String,Dict{Symbol,Any}}(
        "admin-token-abc" => Dict(:user_id => 1, :role => "admin"),
        "dev-token-xyz"   => Dict(:user_id => 2, :role => "developer"),
    )
    plug!(server, InjectUser(admin_tokens); paths=["/admin"])

    # ── Custom error responses ─────────────────────────────────────────────────
    fail!(server, 500, Response(Json, Dict("error"=>"Internal server error"); status=500))
    fail!(server, 413, Response(Json, Dict("error"=>"Request body too large"); status=413))
    fail!(server, 504, Response(Json, Dict("error"=>"Request timed out");      status=504))

    # ── Static file serving (C-level, bypasses middleware pipeline) ────────────
    # All three mounts are auth-free (api_key only covers /api).
    mount!(server, joinpath(@__DIR__, "public"))
    mount!(server, joinpath(@__DIR__, "public", "assets"); uri_prefix="/assets")

    @info "======================================================"
    @info "  Mongoose.jl Comprehensive Demo"
    @info "======================================================"
    @info "  Web UI           →  http://localhost:9000"
    @info "  ── Infra ─────────────────────────────────────────────"
    @info "  Health           →  http://localhost:9000/healthz"
    @info "  Readiness        →  http://localhost:9000/readyz"
    @info "  Liveness         →  http://localhost:9000/livez"
    @info "  Metrics          →  http://localhost:9000/metrics"
    @info "  ── REST API (requires X-API-Key: demo-key-1234) ──────"
    @info "  Ping             →  GET    /api/ping"
    @info "  List users       →  GET    /api/users?role=admin&limit=5&active=true"
    @info "  Get user         →  GET    /api/users/1"
    @info "  Create user      →  POST   /api/users"
    @info "  Patch user       →  PATCH  /api/users/1"
    @info "  Update user      →  PUT    /api/users/1"
    @info "  Delete user      →  DELETE /api/users/1"
    @info "  Float64 params   →  GET    /api/calc/add/1.5/2.3"
    @info "  ── Binary responses ───────────────────────────────────"
    @info "  PNG (generated)  →  GET  /api/image?r=255&g=128&b=0"
    @info "  Protected files  →  GET  /api/protected"
    @info "  CSV download     →  GET  /api/download"
    @info "  ── Admin (requires Bearer token) ─────────────────────"
    @info "  Who am I?        →  GET  /admin/whoami"
    @info "    (Authorization: Bearer admin-token-abc)"
    @info "  Simulate DB down →  PUT  /admin/db/down  (makes /healthz return 503)"
    @info "  Restore DB       →  PUT  /admin/db/up"
    @info "  ── Debug (no auth, no API key) ────────────────────────"
    @info "  Echo request     →  GET  /debug/echo            (see what server parsed)"
    @info "  Echo with body   →  POST /debug/echo            (include a body)"
    @info "  Custom 500       →  GET  /debug/panic"
    @info "  Slow logger      →  GET  /debug/slow?ms=600     (>500ms threshold)"
    @info "  Custom 504       →  GET  /debug/slow?ms=4000    (exceeds 3s timeout)"
    @info "  Format types     →  GET  /debug/formats?type=html|xml|css|js|binary|plain"
    @info "  Trigger 429      →  GET  /debug/limited         (hit 4+ times in 30s)"
    @info "  ── WebSocket ──────────────────────────────────────────"
    @info "  Chat             →  ws://localhost:9000/ws/chat"
    @info "======================================================"

    start!(server; host="0.0.0.0", port=9000, blocking=true)
end

main()
