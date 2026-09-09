module Mongoose

using Mongoose_jll
using PrecompileTools
import JSON
using CodecZlib

export App, ServerConfig, Router, AbstractRouter, Request, Response, StreamResponse,
    Plain, Html, Json, Css, Js, Xml, Binary,
    start!, shutdown!, route!, use!, serve!, onerror!, onstart!, onstop!,
    context, Cookie, Headers, bake, cookies, form, header,
    ws!, Message,
    cors, ratelimit, bearer, apikey, basicauth, logger, health, metrics, security, compress,
    RouteError, ServerError, BindError,
    HTTPError, error_status,
    BadRequestError, UnauthorizedError, PaymentRequiredError, ForbiddenError,
    NotFoundError, MethodNotAllowedError, NotAcceptableError, RequestTimeoutError,
    ConflictError, GoneError, LengthRequiredError, PreconditionFailedError,
    PayloadTooLargeError, URITooLongError, UnsupportedMediaTypeError,
    RangeNotSatisfiableError, ExpectationFailedError, ImATeapotError,
    UnprocessableEntityError, LockedError, FailedDependencyError, TooEarlyError,
    UpgradeRequiredError, PreconditionRequiredError, TooManyRequestsError,
    UnavailableForLegalReasonsError, InternalServerError,
    TLSConfig,
    service!, service, background!,
    AbstractExecutor, SyncExecutor, AsyncExecutor, submit!, stop!, haspending,
    AbstractTransport, FakeTransport, TestClient,
    supports_websocket, supports_tls, supports_streaming,
    group, RouteGroup, mount!,
    freeze!, isfrozen,
    SSEWriter, emit, sse,
    json, html, text, redirect,
    post!, patch!, options!, head!,
    query, body, multipart, MultipartFile,
    validate, ValidationError

# ══════════════════════════════════════════════════════════════════════════════
# 1. Core layer (transport-agnostic; loads standalone, no FFI)
# ══════════════════════════════════════════════════════════════════════════════
include("core/MongooseCore.jl")      # nested module: protocol, router, middleware
using .MongooseCore
# Server/transport layers extend these core generics; `using` alone is read-only.
import .MongooseCore: route!, ws!, post!, patch!, options!, head!,
    submit!, start!, stop!, haspending,
    supports_websocket, supports_tls, supports_streaming,
    terminal_for

# ══════════════════════════════════════════════════════════════════════════════
# 2. FFI Layer (C constants, structs, bindings)
# ══════════════════════════════════════════════════════════════════════════════
include("ffi/constants.jl")
include("ffi/structs.jl")
include("ffi/bindings.jl")

# ══════════════════════════════════════════════════════════════════════════════
# 3. Utilities (server-aware: lifecycle banners / logging)
# ══════════════════════════════════════════════════════════════════════════════
include("util/log.jl")

# ══════════════════════════════════════════════════════════════════════════════
# 4. Server Layer (AbstractServer, App, registry, lifecycle, workers)
# ══════════════════════════════════════════════════════════════════════════════
include("protocol/base.jl")          # abstract type AbstractServer
include("server/core.jl")            # App, Manager, ServerConfig, TLSConfig
include("server/registry.jl")        # Global server registry (GC-safe callback recovery)
include("server/lifecycle.jl")       # start!, shutdown!, TLS, bind, drain
include("server/sync.jl")            # Server event loop
include("server/async.jl")           # Async worker pool

# ══════════════════════════════════════════════════════════════════════════════
# 5. Transport Layer (Mongoose C library adapter)
# ══════════════════════════════════════════════════════════════════════════════
include("transport/mongoose/adapter.jl")      # FFI → Request conversion
include("transport/mongoose/connection.jl")    # send_http_response!, send_ws_frame!, StreamWriter
include("transport/mongoose/ws_handler.jl")    # WS event handlers (upgrade, message, close)
include("transport/mongoose/events.jl")        # C callback dispatch
include("transport/mongoose/http_handler.jl")  # HTTP request processing hot path

# ══════════════════════════════════════════════════════════════════════════════
# 6. Streaming (SSE)
# ══════════════════════════════════════════════════════════════════════════════
include("streaming/sse.jl")

# ══════════════════════════════════════════════════════════════════════════════
# 7. Testing utilities
# ══════════════════════════════════════════════════════════════════════════════
include("testing.jl")

# ══════════════════════════════════════════════════════════════════════════════
# Module initialization
# ══════════════════════════════════════════════════════════════════════════════
function __init__()
    init_tty!()
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

        match_route(router, :get,  "/")
        match_route(router, :get,  "/users/1")
        match_route(router, :post, "/data")
        match_route(router, :get,  "/nonexistent")

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
        context(req)
        header(req, "content-type")
        form_req = Request(:post, "/", Dict{String,String}(),
            ["content-type" => "application/x-www-form-urlencoded"],
            "a=1&b=hello", nothing)
        form(form_req)

        # --- String utilities ---
        sanitize_header_value("abc-123")
        sanitize_header_value("bad\r\nvalue")
        string(UInt64(12345))

        # --- Middleware construction ---
        cors(); cors(origins="https://example.com")
        logger(); ratelimit(); bearer(t -> true)
        apikey(keys=Set(["k"])); health(); metrics()

        # --- App construction ---
        app = App()
        use!(app, cors())
        get!(app, "/") do r; json(Dict("ok" => true)) end
        post!(app, "/data") do r; text("ok") end
        error_response(app.errors, req, 500)

        # --- HTTPError hierarchy + transport fallback ---
        err404 = NotFoundError("user missing")
        error_status(err404)
        sprint(showerror, err404)
        ValidationError("bad field", "age")
        thrower = App()
        get!(thrower, "/bad") do r; throw(BadRequestError("bad input")) end
        get!(thrower, "/gone") do r; throw(NotFoundError("user 7")) end
        req_bad = Request(:get, "/bad", Dict{String,String}(), Pair{String,String}[], "")
        req_gone = Request(:get, "/gone", Dict{String,String}(), Pair{String,String}[], "")
        invoke_guarded(thrower, req_bad, () -> invoke_http(thrower, req_bad))
        invoke_guarded(thrower, req_gone, () -> invoke_http(thrower, req_gone))

        # --- Frozen-router dispatch (compiled table + terminals) ---
        frozen = Router()
        route!(frozen, :get, "/fixed", req -> Response(200, Pair{String,String}[], "f"))
        route!(frozen, :get, "/users/:id::Int", (req, id) -> Response(200, Pair{String,String}[], "u"))
        route!(frozen, :get, "/files/*path", (req, path) -> Response(200, Pair{String,String}[], "w"))
        freeze!(frozen)
        match_route(frozen, :get, "/fixed")
        match_route(frozen, :get, "/users/1")
        match_route(frozen, :get, "/files/a/b")
        invoke_request(frozen, AbstractMiddleware[], Dict{Int,Union{Response,Function}}(),
            NamedTuple(), req)
        invoke_request(frozen, AbstractMiddleware[], Dict{Int,Union{Response,Function}}(),
            NamedTuple(),
            Request(:get, "/users/7", Dict{String,String}(), Pair{String,String}[], ""))

        # --- Event dispatch ---
        is_handled_event(MG_EV_HTTP_MSG)
        is_handled_event(MG_EV_POLL)
    end

    # Precompile C callback entry point
    precompile(c_event_callback, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
end

end # module Mongoose
