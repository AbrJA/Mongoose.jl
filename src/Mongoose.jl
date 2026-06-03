module Mongoose

using Mongoose_jll
using PrecompileTools
using JSON3
using StructTypes
using CodecZlib

export App, Router, Request, Response, StreamResponse,
    Plain, Html, Json, Css, Js, Xml, Binary,
    start!, shutdown!, route!, use!, serve!, onerror!, onstart!, onstop!,
    ctx!, Cookie, Headers, bake, cookies, form, header,
    ws!, Message,
    cors, ratelimit, bearer, apikey, logger, health, metrics, security, compress,
    RouteError, ServerError, BindError,
    TLSConfig,
    provide!, inject, background!,
    group, RouteGroup, mount!,
    SSEWriter, emit, sse,
    json, html, text, redirect,
    post!, patch!, options!, head!,
    query, body, multipart, MultipartFile

# ══════════════════════════════════════════════════════════════════════════════
# 1. FFI Layer (C constants, structs, bindings)
# ══════════════════════════════════════════════════════════════════════════════
include("ffi/constants.jl")
include("ffi/structs.jl")
include("ffi/bindings.jl")

# ══════════════════════════════════════════════════════════════════════════════
# 2. Utilities (no internal dependencies)
# ══════════════════════════════════════════════════════════════════════════════
include("util/errors.jl")
include("util/strings.jl")
include("util/log.jl")

# ══════════════════════════════════════════════════════════════════════════════
# 3. Protocol Layer (transport-agnostic types)
# ══════════════════════════════════════════════════════════════════════════════
include("protocol/base.jl")          # AbstractRequest, AbstractServer
include("protocol/formats.jl")       # Content format types
include("protocol/status.jl")        # status_reason()
include("protocol/request.jl")       # Request struct
include("protocol/response.jl")      # Response, StreamResponse, Cookie
include("protocol/ws_types.jl")      # WsConn, Message, Intent, WsEndpoint, Tagged
include("protocol/context.jl")       # ctx!

# ══════════════════════════════════════════════════════════════════════════════
# 4. Middleware Protocol
# ══════════════════════════════════════════════════════════════════════════════
include("middleware/pipeline.jl")     # AbstractMiddleware, execute_pipeline, use!

# ══════════════════════════════════════════════════════════════════════════════
# 5. Router Layer
# ══════════════════════════════════════════════════════════════════════════════
include("router/interface.jl")        # AbstractRouter protocols
include("router/trie.jl")             # Dynamic Router (trie-based)
include("router/groups.jl")           # Route groups with scoped middleware

# ══════════════════════════════════════════════════════════════════════════════
# 6. Transport Layer (Mongoose C library adapter)
# ══════════════════════════════════════════════════════════════════════════════
include("transport/mongoose/adapter.jl")      # FFI → Request conversion
include("transport/mongoose/connection.jl")    # send_http_response!, send_ws_frame!, StreamWriter

# ══════════════════════════════════════════════════════════════════════════════
# 7. Server Layer
# ══════════════════════════════════════════════════════════════════════════════
include("server/core.jl")             # App, Manager, TLSConfig
include("server/registry.jl")         # Global server registry (GC-safe callback recovery)

# ══════════════════════════════════════════════════════════════════════════════
# 8. Transport Handlers (need Server/Async types)
# ══════════════════════════════════════════════════════════════════════════════
include("transport/mongoose/ws_handler.jl")    # WS event handlers (upgrade, message, close)
include("transport/mongoose/events.jl")        # C callback dispatch
include("transport/mongoose/http_handler.jl")  # HTTP request processing hot path

# ══════════════════════════════════════════════════════════════════════════════
# 9. Server Lifecycle
# ══════════════════════════════════════════════════════════════════════════════
include("server/lifecycle.jl")        # start!, shutdown!, TLS, bind, drain
include("server/sync.jl")             # Server event loop
include("server/async.jl")            # Async worker pool

# ══════════════════════════════════════════════════════════════════════════════
# 8. Middleware Implementations
# ══════════════════════════════════════════════════════════════════════════════
include("middleware/cors.jl")
include("middleware/ratelimit.jl")
include("middleware/auth.jl")
include("middleware/logger.jl")
include("middleware/health.jl")
include("middleware/metrics.jl")
include("middleware/security.jl")
include("middleware/compress.jl")

# ══════════════════════════════════════════════════════════════════════════════
# 9. Streaming (SSE)
# ══════════════════════════════════════════════════════════════════════════════
include("streaming/sse.jl")

# ══════════════════════════════════════════════════════════════════════════════
# 10. Testing utilities
# ══════════════════════════════════════════════════════════════════════════════
include("testing.jl")

# ══════════════════════════════════════════════════════════════════════════════
# Module initialization
# ══════════════════════════════════════════════════════════════════════════════
function __init__()
    init_tty!()
    init_log_backend!()
end

# ══════════════════════════════════════════════════════════════════════════════
# 10. Precompilation
# ══════════════════════════════════════════════════════════════════════════════
@setup_workload begin
    @compile_workload begin
        # --- Router setup ---
        router = Router()
        route!(router, :get,    "/",               req -> Response(200, Pair{String,String}[], ""))
        route!(router, :get,    "/users/:id::Int", (req, id) -> Response(200, Pair{String,String}[], ""))
        route!(router, :post,   "/data",           req -> Response(200, Pair{String,String}[], ""))

        dispatch_route(router, :get,  "/")
        dispatch_route(router, :get,  "/users/1")
        dispatch_route(router, :post, "/data")
        dispatch_route(router, :get,  "/nonexistent")

        # --- Response constructors & helpers ---
        Response(Plain, "ok")
        Response(Json, "{}")
        Response(Html, "<p>ok</p>")
        Response(404, Pair{String,String}[], "")
        Response(500, Pair{String,String}[], "")
        json("{\"ok\":true}")
        html("<b>ok</b>")
        text("hello")
        redirect("/")

        # --- Status reason ---
        status_reason(200); status_reason(404); status_reason(500)

        # --- Request + context ---
        req = Request(:get, "/", Dict{String,String}(), Pair{String,String}[], "", nothing)
        ctx!(req)
        header(req, "content-type")
        form_req = Request(:post, "/", Dict{String,String}(),
            ["content-type" => "application/x-www-form-urlencoded"],
            "a=1&b=hello", nothing)
        form(form_req)

        # --- String utilities ---
        sanitize_header_value("abc-123")
        sanitize_header_value("bad\r\nvalue")
        uint_to_string(UInt64(12345))

        # --- Middleware construction ---
        cors(); cors(origins="https://example.com")
        logger(); ratelimit(); bearer(t -> true)
        apikey(keys=Set(["k"])); health(); metrics()

        # --- App construction ---
        app = App()
        use!(app, cors())
        get!(app, "/") do r; json(Dict("ok" => true)) end
        post!(app, "/data") do r; text("ok") end
        error_response(app, req, 500)

        # --- Event dispatch ---
        is_handled_event(MG_EV_HTTP_MSG)
        is_handled_event(MG_EV_POLL)
    end

    # Precompile C callback entry point
    precompile(c_event_callback, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
end

end # module Mongoose
