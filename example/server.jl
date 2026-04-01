"""
Mongoose.jl Example Server

Demonstrates: CRUD REST, JSON, typed query structs, binary responses (generated
and auth-gated), file downloads, WebSocket, all built-in middleware, custom error
responses, Prometheus metrics, and C-level static file serving.

    julia --project example/server.jl
    open http://localhost:9000
"""

using Mongoose
using JSON
using Dates

Mongoose.render_body(::Type{Json}, body) = JSON.json(body)

const LOCK   = ReentrantLock()
const USERS  = Dict{Int,Dict{String,Any}}(
    1 => Dict("id"=>1,"name"=>"Alice",  "email"=>"alice@example.com",  "role"=>"admin"),
    2 => Dict("id"=>2,"name"=>"Bob",    "email"=>"bob@example.com",    "role"=>"user"),
    3 => Dict("id"=>3,"name"=>"Charlie","email"=>"charlie@example.com","role"=>"user"),
)
const NEXT_ID = Ref(4)

const START_TIME = time()
const REQ_COUNT  = Ref(0)
const ERR_COUNT  = Ref(0)
const WS_COUNT   = Ref(0)
inc!(r) = (r[] += 1)

struct UserFilter
    role::String
    limit::Union{Int,Nothing}
end

struct ImageParams
    r::Union{Int,Nothing}   # default 128
    g::Union{Int,Nothing}   # default 64
    b::Union{Int,Nothing}   # default 200
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
    inc!(REQ_COUNT)
    Response(Json, Dict(
        "pong"     => true,
        "time"     => string(now(UTC)),
        "uptime_s" => round(time() - START_TIME, digits=1),
    ))
end

function handle_list_users(req::Request)
    inc!(REQ_COUNT)
    f = Mongoose.query(UserFilter, req)

    users = lock(LOCK) do
        collect(values(USERS))
    end

    isempty(f.role) || filter!(u -> u["role"] == f.role, users)
    f.limit !== nothing && (users = first(users, min(f.limit, length(users))))
    sort!(users; by = u -> u["id"])

    Response(Json, Dict("users" => users, "count" => length(users)))
end

function handle_get_user(req::Request, id::Int)
    inc!(REQ_COUNT)
    user = lock(LOCK) do; get(USERS, id, nothing) end
    user === nothing && return Response(Json, Dict("error"=>"User $id not found"); status=404)
    Response(Json, user)
end

function handle_create_user(req::Request)
    inc!(REQ_COUNT)
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

function handle_update_user(req::Request, id::Int)
    inc!(REQ_COUNT)
    body = try JSON.parse(req.body) catch; return Response(Json, Dict("error"=>"Invalid JSON"); status=400) end
    updated = lock(LOCK) do
        u = get(USERS, id, nothing)
        u === nothing && return nothing
        for (k,v) in body; k == "id" && continue; u[k] = v end
        u
    end
    updated === nothing && return Response(Json, Dict("error"=>"User $id not found"); status=404)
    Response(Json, updated)
end

function handle_delete_user(req::Request, id::Int)
    inc!(REQ_COUNT)
    d = lock(LOCK) do; pop!(USERS, id, nothing) end
    d === nothing && return Response(Json, Dict("error"=>"User $id not found"); status=404)
    Response(Json, Dict("deleted"=>true, "id"=>id))
end

function handle_image(req::Request)
    inc!(REQ_COUNT)
    p   = Mongoose.query(ImageParams, req)
    r   = UInt8(clamp(something(p.r, 128), 0, 255))
    g   = UInt8(clamp(something(p.g,  64), 0, 255))
    b   = UInt8(clamp(something(p.b, 200), 0, 255))
    png = _make_png(r, g, b)
    Response(200, "Content-Type: image/png\r\nCache-Control: no-cache\r\n", png)
end

function handle_download(req::Request)
    inc!(REQ_COUNT)
    users = lock(LOCK) do; collect(values(USERS)) end
    sort!(users; by = u -> u["id"])
    csv = "id,name,email,role\n" *
          join(["$(u["id"]),$(u["name"]),$(u["email"]),$(u["role"])" for u in users], "\n") * "\n"
    Response(200,
        "Content-Type: text/csv\r\n" *
        "Content-Disposition: attachment; filename=\"users.csv\"\r\n",
        csv)
end

# serve_dir! runs at the C level before middleware, so it cannot enforce auth.
# These routes read files into Vector{UInt8} inside the middleware pipeline,
# where AnyAuth has already checked credentials.
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
    inc!(REQ_COUNT)
    files = isdir(PROTECTED_DIR) ? readdir(PROTECTED_DIR) : String[]
    filter!(f -> haskey(PROTECTED_MIME, lowercase(splitext(f)[2])), files)
    Response(Json, Dict("files" => files))
end

function handle_protected_file(req::Request, name::String)
    inc!(REQ_COUNT)

    # Reject path separators to prevent directory traversal.
    (occursin('/', name) || occursin('\\', name)) &&
        return Response(Json, Dict("error" => "Invalid filename"); status=400)

    path = joinpath(PROTECTED_DIR, name)
    isfile(path) || return Response(Json, Dict("error" => "Not found: $name"); status=404)

    ext  = lowercase(splitext(name)[2])
    mime = get(PROTECTED_MIME, ext, "application/octet-stream")
    data = read(path)

    # ?download=true forces Content-Disposition: attachment regardless of type.
    force_dl = occursin("download=true", req.query) || occursin("download=1", req.query)
    disp = force_dl ? "attachment" :
           startswith(mime, "image/") || mime == "application/pdf" ? "inline" : "attachment"

    Response(200,
        "Content-Type: $mime\r\n" *
        "Content-Disposition: $disp; filename=\"$name\"\r\n",
        data)
end

function handle_metrics(req::Request)
    uptime = round(time() - START_TIME, digits=1)
    body = strip("""
# HELP mongoose_requests_total Total HTTP requests
# TYPE mongoose_requests_total counter
mongoose_requests_total $(REQ_COUNT[])

# HELP mongoose_errors_total Total handler errors
# TYPE mongoose_errors_total counter
mongoose_errors_total $(ERR_COUNT[])

# HELP mongoose_ws_connections Active WebSocket connections
# TYPE mongoose_ws_connections gauge
mongoose_ws_connections $(WS_COUNT[])

# HELP mongoose_uptime_seconds Server uptime in seconds
# TYPE mongoose_uptime_seconds gauge
mongoose_uptime_seconds $uptime

# HELP mongoose_users_total Users in store
# TYPE mongoose_users_total gauge
mongoose_users_total $(lock(LOCK) do; length(USERS) end)
""")
    Response(200, "Content-Type: text/plain; version=0.0.4\r\n", String(body))
end

function ws_open(req::Request)
    inc!(WS_COUNT)
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

# Custom middleware: passes if either X-API-Key or Authorization: Bearer matches.
struct AnyAuth <: Mongoose.AbstractMiddleware
    keys::Set{String}
    tokens::Set{String}
    key_header::String
end

function (mw::AnyAuth)(req::Mongoose.AbstractRequest, params::Vector{Any}, next)
    api_key_val = get(req.headers, mw.key_header, "")
    !isempty(api_key_val) && api_key_val ∈ mw.keys && return next()

    auth = get(req.headers, "authorization", "")
    if length(auth) > 7 && lowercase(auth[1:7]) == "bearer "
        token = strip(auth[8:end])
        !isempty(token) && token ∈ mw.tokens && return next()
    end

    Response(401,
        "Content-Type: application/json; charset=utf-8\r\n" *
        "WWW-Authenticate: Bearer realm=\"api\", error=\"invalid_token\"\r\n",
        "{\"error\":\"Unauthorized: provide a valid X-API-Key header or Authorization: Bearer token\"}")
end

# ─── Build & start ─────────────────────────────────────────────────────────────
function main()
    router = Router()

    # ── REST routes ────────────────────────────────────────────────────────
    route!(router, :get,    "/api/ping",           handle_ping)
    route!(router, :get,    "/api/users",           handle_list_users)
    route!(router, :get,    "/api/users/:id::Int",  handle_get_user)
    route!(router, :post,   "/api/users",           handle_create_user)
    route!(router, :put,    "/api/users/:id::Int",  handle_update_user)
    route!(router, :delete, "/api/users/:id::Int",  handle_delete_user)

    # ── Binary responses ────────────────────────────────────────────────────
    route!(router, :get, "/api/image",    handle_image)          # generated PNG
    route!(router, :get, "/api/protected",            handle_protected_list)
    route!(router, :get, "/api/protected/:name::String", handle_protected_file)
    route!(router, :get, "/api/download", handle_download)

    route!(router, :get, "/metrics", handle_metrics)  # no auth

    # ── WebSocket ──────────────────────────────────────────────────────────
    ws!(router, "/ws/chat";
        on_open    = ws_open,
        on_message = ws_message,
        on_close   = ws_close,
    )

    # ── Server ─────────────────────────────────────────────────────────────
    server = AsyncServer(router; workers=4, nqueue=2048, request_timeout_ms=15_000)

    # ── Middleware ─────────────────────────────────────────────────────────
    use!(server, cors(
        origins = "*",
        methods = "GET, POST, PUT, DELETE, OPTIONS",
        headers = "Content-Type, Authorization, X-API-Key",
    ))
    use!(server, logger(structured=true))
    use!(server, rate_limit(max_requests=300, window_seconds=60))
    use!(server, health())   # registers /healthz, /readyz, /livez

    # AnyAuth: accepts X-API-Key or Bearer token, scoped to /api only.
    valid_keys   = Set(["demo-key-1234", "prod-key-secret"])
    valid_tokens = Set(["secret-token",  "prod-bearer-token"])
    use!(server, AnyAuth(valid_keys, valid_tokens, "x-api-key"); paths=["/api"])

    error_response!(server, 500, Response(Json, Dict("error"=>"Internal server error"); status=500))
    error_response!(server, 413, Response(Json, Dict("error"=>"Request body too large"); status=413))
    error_response!(server, 504, Response(Json, Dict("error"=>"Request timed out"); status=504))

    serve_dir!(server, joinpath(@__DIR__, "public"))                              # GET /* → public/*
    serve_dir!(server, joinpath(@__DIR__, "public", "assets"); uri_prefix="/assets") # GET /assets/* → public/assets/*

    @info "======================================================"
    @info "  Mongoose.jl Comprehensive Demo"
    @info "======================================================"
    @info "  Web UI         →  http://localhost:9000"
    @info "  Health         →  http://localhost:9000/healthz"
    @info "  Metrics        →  http://localhost:9000/metrics"
    @info "  REST API       →  http://localhost:9000/api/ping"
    @info "                 →  (requires X-API-Key: demo-key-1234)"
    @info "  ── Binary responses ──────────────────────────────────"
    @info "  PNG (generated) → http://localhost:9000/api/image?r=255&g=128&b=0"
    @info "  Protected files → http://localhost:9000/api/protected"
    @info "  ── Other ────────────────────────────────────────────"
    @info "  CSV download   →  http://localhost:9000/api/download"
    @info "  WebSocket      →  ws://localhost:9000/ws/chat"
    @info "  Protected dir  →  $(PROTECTED_DIR)"
    @info "  Auth (either one works):"
    @info "    API key  →  X-API-Key: demo-key-1234"
    @info "    Bearer   →  Authorization: Bearer secret-token"
    @info "======================================================"

    start!(server; host="0.0.0.0", port=9000, blocking=true)
end

main()
