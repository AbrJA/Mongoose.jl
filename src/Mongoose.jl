module Mongoose

using Mongoose_jll
using PrecompileTools

export Server, Async, Router, Request, Response, StreamResponse, Headers,
    Plain, Html, Json, Css, Js, Xml, Binary,
    start!, shutdown!, route!, plug!, mount!, fail!,
    context!, Cookie, serialize_cookie, parse_cookies,
    ws!, Message,
    cors, ratelimit, bearer, apikey, logger, health, metrics, security,
    RouteError, ServerError, BindError,
    @router,
    Config, TLSConfig,
    ServiceRegistry, register!, service,
    group, RouteGroup, register_group!,
    SSEWriter, event!, sse_response

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
include("protocol/ws_types.jl")      # WsConn, Message, Intent, WsEndpoint, Tagged, Call, Reply
include("protocol/context.jl")       # ServiceRegistry

# ══════════════════════════════════════════════════════════════════════════════
# 4. Middleware Protocol
# ══════════════════════════════════════════════════════════════════════════════
include("middleware/pipeline.jl")     # AbstractMiddleware, execute_pipeline, plug!

# ══════════════════════════════════════════════════════════════════════════════
# 5. Router Layer
# ══════════════════════════════════════════════════════════════════════════════
include("router/interface.jl")        # AbstractRouter, StaticRouter protocols
include("router/static.jl")           # @router macro + static dispatch
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
include("server/core.jl")             # Manager, TLSConfig, ServerCore, Server, Async types
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

# ══════════════════════════════════════════════════════════════════════════════
# 9. Streaming (SSE)
# ══════════════════════════════════════════════════════════════════════════════
include("streaming/sse.jl")

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
        route!(router, :get,    "/",               req -> Response(200, "", ""))
        route!(router, :get,    "/users/:id::Int", (req, id) -> Response(200, "", ""))
        route!(router, :post,   "/data",           req -> Response(200, "", ""))
        route!(router, :delete, "/data/:id::Int",  (req, id) -> Response(200, "", ""))

        dispatch_route(router, :get,  "/")
        dispatch_route(router, :get,  "/users/1")
        dispatch_route(router, :post, "/data")
        dispatch_route(router, :get,  "/nonexistent")

        # --- Response constructors ---
        Response(Plain, "ok")
        Response(Json, "{}")
        Response(Html, "<p>ok</p>")
        Response(Plain, "ok"; status=200)
        Response(404, "", "")
        Response(500, "", "")
        Response(204, "", "")
        Response(200, "", UInt8[])

        # --- Status reason ---
        status_reason(200); status_reason(201); status_reason(204)
        status_reason(301); status_reason(302); status_reason(304)
        status_reason(400); status_reason(401); status_reason(403); status_reason(404)
        status_reason(405); status_reason(413); status_reason(429)
        status_reason(500); status_reason(503); status_reason(504)

        # --- Request + context ---
        req = Request(:get, "/", Dict{String,String}(), Pair{String,String}[], "", nothing)
        req_with_headers = Request(:get, "/users/1", Dict("a" => "1", "b" => "2"),
            ["content-type" => "application/json", "authorization" => "Bearer tok",
             "x-request-id" => "abc-123", "x-forwarded-for" => "10.0.0.1"],
            "{}", nothing)
        context!(req)

        # --- String utilities ---
        sanitize_header_value("abc-123")
        sanitize_header_value("bad\r\nvalue")
        uint_to_string(UInt64(12345))

        # --- Middleware construction ---
        mw_cors     = cors()
        mw_cors2    = cors(origins="https://example.com", methods="GET,POST")
        mw_logger   = logger(threshold=100)
        mw_logger2  = logger(threshold=100, structured=true)
        mw_rl       = ratelimit()
        mw_rl2      = ratelimit(max_requests=10, window_seconds=30)
        mw_bearer   = bearer(t -> true)
        mw_apikey   = apikey(keys=Set(["k"]))
        mw_health   = health()
        mw_metrics  = metrics()

        # --- Middleware call operators ---
        noop = () -> Response(200, "", "ok")
        mw_cors(req, noop)
        mw_cors(req_with_headers, noop)
        mw_logger(req, noop)
        mw_logger2(req, noop)
        mw_rl(req_with_headers, noop)
        mw_bearer(req_with_headers, noop)
        mw_apikey(req_with_headers, noop)
        mw_health(req, noop)
        mw_health(Request(:get, "/healthz", Dict{String,String}(), Pair{String,String}[], "", nothing), noop)
        mw_health(Request(:get, "/readyz",  Dict{String,String}(), Pair{String,String}[], "", nothing), noop)
        mw_health(Request(:get, "/livez",   Dict{String,String}(), Pair{String,String}[], "", nothing), noop)
        mw_metrics(req, noop)

        # --- PathFilter ---
        pf = PathFilter(mw_cors, ["/api"])
        pf(Request(:get, "/api/users", Dict{String,String}(), Pair{String,String}[], "", nothing), noop)

        # --- Full pipeline ---
        execute_pipeline(AbstractMiddleware[mw_cors, mw_logger], req,
                         (r) -> dispatch_to_handler(router, r))

        # --- invoke_http ---
        server_sync  = Server(router)
        server_async = Async(router; nworkers=1)
        plug!(server_sync,  cors())
        plug!(server_async, cors())

        invoke_http(server_sync,  req)
        invoke_http(server_async, req)
        invoke_http(server_sync,  req_with_headers)

        # --- Error responses ---
        error_response(server_sync, 500)
        error_response(server_sync, 413)
        error_response(server_sync, 503)
        error_response(server_sync, 504)

        # --- Event dispatch ---
        is_handled_event(MG_EV_HTTP_MSG)
        is_handled_event(MG_EV_POLL)
        for ev in (MG_EV_HTTP_MSG, MG_EV_WS_MSG, MG_EV_WS_CTL, MG_EV_CLOSE, MG_EV_WS_OPEN)
            try dispatch_event(server_sync,  ev, MgConnection(C_NULL), C_NULL) catch end
            try dispatch_event(server_async, ev, MgConnection(C_NULL), C_NULL) catch end
        end

        # --- Config ---
        Config()
        Config(nworkers=2, max_body=1024)
        Config(nworkers=8, request_timeout=5000, drain_timeout=10_000, ws_idle_timeout=60)
    end

    # Precompile C callback entry point
    precompile(c_event_callback, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
end

end # module Mongoose
