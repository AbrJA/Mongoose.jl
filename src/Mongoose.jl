module Mongoose

using Mongoose_jll

export AsyncServer, SyncServer, Request, Response, HttpRequest, HttpResponse, start!, shutdown!, route!, use!, from_query, to_headers, ws!, WsMessage, send_ws

# FFI Layer
include("ffi/constants.jl")
include("ffi/structs.jl")
include("ffi/bindings.jl")

# Core Layer Types
include("core/types.jl")
include("core/errors.jl")

# WS Types and Router (needed by ServerCore)
include("ws/types.jl")
include("ws/router.jl")

# Core Server Implementation
include("core/server.jl")
include("core/registry.jl")
include("core/middleware.jl")
include("core/events.jl")
include("core/lifecycle.jl")

# HTTP Layer
include("http/types.jl")
include("http/router.jl")
include("http/builder.jl")
include("http/handler.jl")
include("http/utils.jl")

# Server Implementations
include("servers/sync.jl")
include("servers/async.jl")

# WS Handler
include("ws/handler.jl")

end
