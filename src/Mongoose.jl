module Mongoose

using Mongoose_jll
using PrecompileTools

export SyncServer, AsyncServer, Router, Request, Response, Message,
    Text, Html, Json, Css, Js, Xml, Binary,
    start!, shutdown!, route!, use!, serve_dir!,
    render_body, content_type,
    ws!,
    cors, rate_limit, bearer_token, api_key, logger, static_files, health,
    ContentType,
    RouteError, ServerError, BindError,
    @router

# Maybe is good to have parse_ and req_

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
include("middleware/static_files.jl")
include("middleware/health.jl")

# 8. Precompilation
@setup_workload begin
    @compile_workload begin
        # Router construction and route registration
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", ""))
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
        route!(router, :post, "/data", req -> Response(200, "", ""))

        # Route matching (hot path)
        _matchroute(router, :get, "/")
        _matchroute(router, :get, "/users/1")
        _matchroute(router, :post, "/data")
        _matchroute(router, :get, "/nonexistent")

        # Response construction
        Response(200, ContentType.text, "ok")
        Response(404, "", "")

        # Middleware construction
        cors()
        logger()
        rate_limit()
        bearer_token(t -> true)
        api_key(keys=Set(["k"]))

        # HTTP dispatch pipeline
        req = Request(:get, "/", "", Pair{String,String}[], "", Dict{Symbol,Any}())
        _dispatchreq(router, req)

        # Middleware pipeline
        mw = cors()
        _pipeline(AbstractMiddleware[mw], req, Any[], (r, args...) -> Response(200, "", ""))
    end
end

end # module Mongoose
