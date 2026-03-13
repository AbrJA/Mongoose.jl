module Mongoose

using Mongoose_jll

export AsyncServer, SyncServer, Request, Response, HttpRequest, HttpResponse, start!, shutdown!, route!, use!, from_query, to_headers

# FFI Layer
include("ffi/constants.jl")
include("ffi/structs.jl")
include("ffi/bindings.jl")

# Core Layer
include("core/types.jl")
include("core/errors.jl")
include("core/server.jl")
include("core/registry.jl")
include("core/middleware.jl")
include("core/events.jl")
include("core/lifecycle.jl") # Added this

# HTTP Layer
include("http/types.jl")
include("http/router.jl")
include("http/builder.jl") # Handled build_request here
include("http/handler.jl")
include("http/utils.jl")

# Server Implementations
include("servers/sync.jl")
include("servers/async.jl")

end
