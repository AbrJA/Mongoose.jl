"""
    AbstractServer — the server protocol.

    `App` is the built-in implementation; custom server types implement the
    same surface (or subtype `App`). Registration helpers (`route!`, `ws!`,
    `use!`, `serve!`, `onerror!`, `onstart!`, `onstop!`) and the read-side
    router protocol (`freeze!`, `isfrozen`, `matchroute`, `hasroute`,
    `haswsroutes`, `getwsendpoint`, `length`) all work without reaching
    through `server.router`.
"""
abstract type AbstractServer end

# --- Router introspection on the server ---
# Mutation is server-level (`route!`, `ws!`, `use!`); mirror the read-only
# protocol here so callers never need `server.router`.

"""
    freeze!(server) → server

Close and compile the server's route table: later `route!`/`ws!` throw
`RouteError`. See [`freeze!`](@ref) on routers for the compiled-dispatch
details.
"""
freeze!(server::AbstractServer) = (freeze!(server.router); server)

"""
    isfrozen(server) → Bool

Whether the server's route table has been closed by `freeze!`.
"""
isfrozen(server::AbstractServer) = isfrozen(server.router)

Base.length(server::AbstractServer) = length(server.router)
Base.isempty(server::AbstractServer) = length(server.router) == 0

"""
    matchroute(server, method, path) → RouteResult

Resolve a request against the server's router, without running handlers.
See [`matchroute`](@ref).
"""
matchroute(server::AbstractServer, method, path::AbstractString) =
    matchroute(server.router, method, path)

"""
    hasroute(server, path) → Bool

Whether the server's router owns `path` (catch-all excluded). See
[`hasroute`](@ref).
"""
hasroute(server::AbstractServer, path::AbstractString) = hasroute(server.router, path)

"""
    haswsroutes(server) → Bool

Whether the server serves any WebSocket endpoints. See [`haswsroutes`](@ref).
"""
haswsroutes(server::AbstractServer) = haswsroutes(server.router)

"""
    getwsendpoint(server, uri) → Union{Nothing,WSEndpoint}

Resolve the WebSocket endpoint for `uri`, or `nothing`. See
[`getwsendpoint`](@ref).
"""
getwsendpoint(server::AbstractServer, uri::AbstractString) =
    getwsendpoint(server.router, uri)

"""
    isrunning(server) → Bool

Whether the server's event loop is currently running (started and not yet shut
down).
"""
isrunning(server::AbstractServer) = server.runtime.running[]

"""
    url(server) → Union{Nothing,String}

The bound base URL (e.g. `"http://127.0.0.1:8080"`) while running, `nothing`
otherwise.
"""
url(server::AbstractServer) = server.runtime.url
