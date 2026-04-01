module Mongoose

using Mongoose_jll
using PrecompileTools

export SyncServer, AsyncServer, Router, Request, Response,
    Text, Html, Json, Css, Js, Xml, Binary,
    start!, shutdown!, route!, use!, serve_dir!, error_response!,
    render_body, content_type, getcontext!,
    ws!, Message,
    cors, rate_limit, bearer_token, api_key, logger, health, metrics,
    ContentType,
    RouteError, ServerError, BindError,
    @router,
    ServerConfig

# 1. FFI Layer (Constants, Structs, Bindings)
include("ffi/constants.jl")
include("ffi/structs.jl")
include("ffi/bindings.jl")

# 2. Base Types and Errors
include("core/types.jl")
include("core/errors.jl")
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
include("middleware/rate_limit.jl")
include("middleware/auth.jl")
include("middleware/logger.jl")
include("middleware/health.jl")
include("middleware/metrics.jl")

# 8. Precompilation
@setup_workload begin
    @compile_workload begin
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", ""))
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
        route!(router, :post, "/data", req -> Response(200, "", ""))

        _matchroute(router, :get, "/")
        _matchroute(router, :get, "/users/1")
        _matchroute(router, :post, "/data")
        _matchroute(router, :get, "/nonexistent")

        Response(200, ContentType.text, "ok")
        Response(200, "ok")
        Response(404, "", "")

        cors()
        logger()
        logger(structured=true)
        rate_limit()
        bearer_token(t -> true)
        api_key(keys=Set(["k"]))

        # context is lazily allocated on first getcontext! call
        req = Request(:get, "/", "", Pair{String,String}[], "", nothing)
        _dispatchreq(router, req)
        getcontext!(req)

        # query parsing
        struct QueryTest
            q::String
            page::Int
        end
        _req_q = Request(:get, "/", "q=hello&page=1", Pair{String,String}[], "", nothing)
        query(QueryTest, _req_q)

        mw = cors()
        _pipeline(AbstractMiddleware[mw], req, Any[], (r, args...) -> Response(200, "", ""))

        # metrics
        mw_metrics = metrics()
        mw_metrics(req, Any[], () -> Response(200, "", "ok"))

        # ServerConfig
        ServerConfig()
        ServerConfig(workers=2, max_body_size=1024)
    end
end

end # module Mongoose
