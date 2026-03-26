module Mongoose

using Mongoose_jll
using PrecompileTools

export SyncServer, AsyncServer, Router, Request, Response, Headers, 
    JsonResponse, HtmlResponse, TextResponse, JsResponse, CssResponse,
    start!, shutdown!, route!, use!,
    header, req_header, query, context, parse_query, parse_into, parse_params,
    ws!, WsTextMessage, WsBinaryMessage, WsMessage,
    cors, rate_limit, auth_bearer, auth_api_key, logger,
    static_files, ContentType,
    @router

# Maybe is good to have parse_ and req_

# JSON stub — extended by MongooseJSONExt when JSON.jl is loaded
function json end

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

# 8. Precompilation
@setup_workload begin
    @compile_workload begin
        # Router construction and route registration
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", ""))
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
        route!(router, :post, "/data", req -> Response(200, "", ""))

        # Route matching (hot path)
        match_route(router, :get, "/")
        match_route(router, :get, "/users/1")
        match_route(router, :post, "/data")
        match_route(router, :get, "/nonexistent")

        # Response construction
        Response(200, ContentType.text, "ok")
        Response(404, "", "")

        # Middleware construction
        cors()
        logger()
        rate_limit()
        auth_bearer(t -> true)
        auth_api_key(keys=Set(["k"]))

        # HTTP dispatch pipeline
        req = Request(:get, "/", "", Headers(), "", Dict{Symbol,Any}())
        _dispatch_to_router(router, req)

        # Middleware pipeline
        mw = cors()
        execute_middleware(Middleware[mw], req, Any[], (r, args...) -> Response(200, "", ""))
    end
end

end # module Mongoose
