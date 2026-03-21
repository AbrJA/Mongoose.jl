module Mongoose

using Mongoose_jll
using PrecompileTools

export SyncServer, AsyncServer, Router, Request, Response,
       start!, shutdown!, route!, use!,
       parse_into, parse_params,
       ws!, WsTextMessage, WsBinaryMessage, WsMessage,
       header, body, query, context,
       cors, rate_limit, auth_bearer, auth_api_key, logger,
       json_response, json_body,
       static_files,
       @router

# 1. FFI Layer (Constants, Structs, Bindings)
include("ffi/constants.jl")
include("ffi/structs.jl")
include("ffi/bindings.jl")

# 2. Base Types and Errors
include("core/types.jl")
include("core/errors.jl")
include("http/types.jl")      # Defines AbstractRouter
include("ws/types.jl")        # WsEndpoint, WsMessage types

# 3. Router Implementations
include("router/static.jl") # Define StaticRouter first
include("router/dynamic.jl")        # Router
include("ws/router.jl")          # ws! registration, static_ws_upgrade

# 4. Core Server Logic
include("core/server.jl")     # ServerCore
include("core/registry.jl")
include("core/middleware.jl")
include("core/events.jl")     # Uses Router for Fallbacks
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

# 8. JSON stubs — implementations loaded by ext/MongooseJSONExt.jl
function json_response end
function json_body end

# 8. Precompilation
@setup_workload begin
    @compile_workload begin
        # Router construction and route registration
        router = Router()
        route!(router, :get, "/", req -> Response(200, "", ""))
        route!(router, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
        route!(router, :post, "/data", req -> Response(200, "", ""))

        # Route matching (hot path)
        _match_route(router, :get, "/")
        _match_route(router, :get, "/users/1")
        _match_route(router, :post, "/data")
        _match_route(router, :get, "/nonexistent")

        # Response construction
        Response(200, "Content-Type: text/plain\r\n", "ok")
        Response(404, "", "")

        # Middleware construction
        cors()
        logger()
        rate_limit()
        auth_bearer(t -> true)
        auth_api_key(keys=Set(["k"]))

        # HTTP dispatch pipeline
        req = Request(:get, "/", "", Dict{String,String}(), "", Dict{Symbol,Any}())
        _dispatch_to_router(router, req)

        # Middleware pipeline
        mw = cors()
        execute_middleware(Middleware[mw], req, Any[], (r, args...) -> Response(200, "", ""))
    end
end

end # module Mongoose
