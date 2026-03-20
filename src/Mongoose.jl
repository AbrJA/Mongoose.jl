module Mongoose

using Mongoose_jll

export SyncServer, AsyncServer, Router, Request, Response,
       start!, shutdown!, route!, use!,
       parse_into,
       ws!, WsTextMessage, WsBinaryMessage, WsMessage,
       header, body, query,
       cors_middleware, rate_limit_middleware, bearer_auth_middleware, api_key_middleware,
       json_response, json_body,
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
include("http/builder.jl")
include("http/handler.jl")
include("http/utils.jl")
include("http/json.jl")
include("ws/handler.jl")

# 6. Server Implementations
include("servers/sync.jl")
include("servers/async.jl")

# 7. Middleware
include("middleware/cors.jl")
include("middleware/rate_limit.jl")
include("middleware/auth.jl")

end # module Mongoose
