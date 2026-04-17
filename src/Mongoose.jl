module Mongoose

using Mongoose_jll
using PrecompileTools

export Server, Async, Router, Request, Response,
    Plain, Html, Json, Css, Js, Xml, Binary,
    start!, shutdown!, route!, plug!, mount!, fail!,
    context!, query,
    ws!, Message,
    cors, ratelimit, bearer, apikey, logger, health, metrics,
    RouteError, ServerError, BindError,
    @router,
    Config

# 1. FFI Layer (Constants, Structs, Bindings)
include("ffi/constants.jl")
include("ffi/structs.jl")
include("ffi/bindings.jl")

# 2. Base Types and Errors
include("core/types.jl")
include("core/errors.jl")
include("core/log.jl")
include("http/types.jl")
include("ws/types.jl")

# 3. Router Implementations
include("router/static.jl")
include("router/dynamic.jl")
include("ws/router.jl")

# 4. Core Server Logic
include("core/server.jl")
include("core/registry.jl")
include("core/middleware.jl")
include("core/events.jl")
include("core/lifecycle.jl")

# 5. Protocol Handlers
include("http/handler.jl")
include("http/utils.jl")
include("ws/handler.jl")

# 6. Server Implementations
include("servers/sync.jl")
include("servers/async.jl")

# 7. Middleware
include("middleware/cors.jl")
include("middleware/ratelimit.jl")
include("middleware/auth.jl")
include("middleware/logger.jl")
include("middleware/health.jl")
include("middleware/metrics.jl")

function __init__()
    _init_tty()
    _init_log_backend!()
end

# 8. Precompilation
@setup_workload begin
    @compile_workload begin
        # --- Router setup ---
        router = Router()
        route!(router, :get,    "/",              req -> Response(200, "", ""))
        route!(router, :get,    "/users/:id::Int", (req, id) -> Response(200, "", ""))
        route!(router, :post,   "/data",           req -> Response(200, "", ""))
        route!(router, :delete, "/data/:id::Int",  (req, id) -> Response(200, "", ""))

        _matchroute(router, :get,  "/")
        _matchroute(router, :get,  "/users/1")
        _matchroute(router, :post, "/data")
        _matchroute(router, :get,  "/nonexistent")

        # --- Response constructors (all common forms) ---
        Response(Plain, "ok")
        Response(Json, "{}")
        Response(Html, "<p>ok</p>")
        Response(Plain, "ok"; status=200)
        Response(404, "", "")
        Response(500, "", "")
        Response(204, "", "")
        Response(200, "", UInt8[])     # binary body path

        # --- Status text ---
        _statustext(200); _statustext(201); _statustext(202); _statustext(204)
        _statustext(206); _statustext(301); _statustext(302); _statustext(304)
        _statustext(400); _statustext(401); _statustext(403); _statustext(404)
        _statustext(405); _statustext(408); _statustext(413); _statustext(429)
        _statustext(500); _statustext(503); _statustext(504)

        # --- Request + context ---
        req = Request(:get, "/", "", Pair{String,String}[], "", nothing)
        req_with_headers = Request(:get, "/users/1", "a=1&b=2",
            ["content-type" => "application/json", "authorization" => "Bearer tok",
             "x-request-id" => "abc-123", "x-forwarded-for" => "10.0.0.1"],
            "{}", nothing)
        context!(req)

        # --- _sendhttp! (string and binary) ---
        # These compile the serialization path without a real socket
        _statustext(200)
        _appendreqid("", "42")
        _appendreqid(_contentheader(Json), "abc-123")
        _sanitizeid("abc-123")
        _sanitizeid("bad\r\nvalue")
        _uint64tostr(UInt64(12345))

        # --- Query parsing ---
        struct QueryTest
            q::String
            page::Int
        end
        _req_q = Request(:get, "/search", "q=hello&page=1", Pair{String,String}[], "", nothing)
        query(QueryTest, _req_q)
        query(QueryTest, "q=world&page=2")

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

        # --- Middleware call operators (hot path in _pipeline) ---
        noop = () -> Response(200, "", "ok")
        mw_cors(req, Any[], noop)
        mw_cors(req_with_headers, Any[], noop)
        mw_logger(req, Any[], noop)
        mw_logger2(req, Any[], noop)
        mw_rl(req_with_headers, Any[], noop)
        mw_bearer(req_with_headers, Any[], noop)
        mw_apikey(req_with_headers, Any[], noop)
        mw_health(req, Any[], noop)
        mw_health(Request(:get, "/healthz", "", Pair{String,String}[], "", nothing), Any[], noop)
        mw_health(Request(:get, "/readyz",  "", Pair{String,String}[], "", nothing), Any[], noop)
        mw_health(Request(:get, "/livez",   "", Pair{String,String}[], "", nothing), Any[], noop)
        mw_metrics(req, Any[], noop)

        # --- PathFilter (path-scoped middleware) ---
        pf = PathFilter(mw_cors, ["/api"])
        pf(req, Any[], noop)
        pf(Request(:get, "/api/users", "", Pair{String,String}[], "", nothing), Any[], noop)

        # --- Full _pipeline with multiple middleware ---
        _pipeline(AbstractMiddleware[mw_cors, mw_logger], req, Any[],
                  (r, args...) -> _dispatchhttp(router, r))

        # --- _invokehttp (the actual request dispatch hot path) ---
        server_sync  = Server(router)
        server_async = Async(router; nworkers=1)
        plug!(server_sync,  cors())
        plug!(server_async, cors())

        _invokehttp(server_sync,  req)
        _invokehttp(server_async, req)
        _invokehttp(server_sync,  req_with_headers)

        # --- Error responses ---
        _errresponse(server_sync, 500)
        _errresponse(server_sync, 413)
        _errresponse(server_sync, 503)
        _errresponse(server_sync, 504)
        _handleerror(server_sync, req, ErrorException(""))

        # --- Event dispatch chain (prevents JIT inside C callback frames) ---
        _ishandled(MG_EV_HTTP_MSG)
        _ishandled(MG_EV_POLL)
        for ev in (MG_EV_HTTP_MSG, MG_EV_WS_MSG, MG_EV_WS_CTL, MG_EV_CLOSE, MG_EV_WS_OPEN)
            try _dispatchev(server_sync,  ev, MgConnection(C_NULL), C_NULL) catch end
            try _dispatchev(server_async, ev, MgConnection(C_NULL), C_NULL) catch end
        end

        # --- Config ---
        Config()
        Config(nworkers=2, max_body=1024)
        Config(nworkers=8, request_timeout=5000, drain_timeout=10_000, ws_idle_timeout=60)
    end

    # Precompile the C callback entry point at module level (outside @compile_workload
    # because it cannot be called safely without a real Mongoose connection pointer)
    precompile(_callbackev, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
end

end # module Mongoose
