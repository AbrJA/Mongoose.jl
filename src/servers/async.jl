"""
    Async — Multi-threaded server methods.
"""

"""
    _tryput!(ch, val, capacity) → Bool

Non-blocking `put!`. Returns `false` when the channel is full or closed,
instead of blocking the caller. Safe when there is a single producer
(the event-loop task), which is always the case in Mongoose.jl.

`capacity` must equal the buffer size the channel was created with.
`Base.n_avail` is an internal function; we use it here because
`length(::Channel)` is not defined in Julia 1.12, making this the only
reliable occupancy check without blocking.
"""
@inline function _tryput!(ch::Channel, val, capacity::Int)
    isopen(ch) || return false
    Base.n_avail(ch) >= capacity && return false
    try
        put!(ch, val)
    catch e
        # Channel was closed between the isopen check and put! (shutdown race).
        e isa InvalidStateException || rethrow(e)
        return false
    end
    return true
end

"""
    Async(router=Router(); nworkers=4, nqueue=1024, poll_timeout=0, max_body,
               drain_timeout, request_timeout=0, errors=Dict{Int,Response}())

Create a multi-threaded server with `nworkers` background tasks.
Not compatible with `juliac --trim=safe`.

# Keyword Arguments
- `nworkers::Integer`: Number of worker tasks (default: `4`).
- `nqueue::Integer`: Channel buffer size (default: `1024`).
- `poll_timeout::Integer`: Event-loop poll timeout in ms (default: `0`).
- `max_body::Integer`: Maximum request body size in bytes (default: 1MB).
- `drain_timeout::Integer`: Graceful shutdown drain timeout (default: 5000ms).
- `request_timeout::Integer`: Per-request timeout in ms, 0 = disabled (default: `0`).
- `errors::Dict{Int,Response}`: Custom responses keyed by HTTP status code (`500`, `413`, `504`). See `fail!`.
"""
Async(::Type{T}; kwargs...) where {T <: StaticRouter} = Async(T(); kwargs...)
Async(::Type{T}, config::Config) where {T <: StaticRouter} = Async(T(), config)

function Async(router::AbstractRouter=Router();
                     nworkers::Integer=4,
                     nqueue::Integer=1024,
                     poll_timeout::Integer=0,
                     max_body::Integer=MAX_BODY,
                     drain_timeout::Integer=DRAIN_TIMEOUT,
                     request_timeout::Integer=0,
                     ws_idle_timeout::Integer=0,
                     errors::Dict{Int,Response}=Dict{Int,Response}(),
                     styled::Bool=isa(stdout, Base.TTY))
    c_handler = Mongoose._cfnasync(typeof(router))
    core = ServerCore(poll_timeout, router; max_body=max_body, drain_timeout=drain_timeout,
                      request_timeout=request_timeout, ws_idle_timeout=ws_idle_timeout,
                      errors=errors, c_handler=c_handler, styled=styled)
    server = Async{typeof(router)}(
        core, Task[],  # workers
        Channel{Call}(nqueue), Channel{Reply}(nqueue),
        Dict{Int,MgConnection}(), Int(nworkers), Int(nqueue)
    )
    finalizer(_teardown!, server)
    return server
end

"""
    Async(router, config::Config)

Create an `Async` from a [`Config`](@ref) struct.
"""
function Async(router::AbstractRouter, config::Config)
    return Async(router;
        nworkers = config.nworkers,
        nqueue = config.nqueue,
        poll_timeout = config.poll_timeout,
        max_body = config.max_body,
        drain_timeout = config.drain_timeout,
        request_timeout = config.request_timeout,
        ws_idle_timeout = config.ws_idle_timeout,
        errors = config.errors
    )
end

function _init!(server::Async)
    server.core.manager = Manager()
    server.calls   = Channel{Call}(server.nqueue)
    server.replies = Channel{Reply}(server.nqueue)
    empty!(server.connections)
    empty!(server.core.ws_clients)
    return
end

function _spawnworkers!(server::Async)
    empty!(server.workers)
    for i in 1:server.nworkers
        t = Threads.@spawn _workloop(server)
        push!(server.workers, t)
    end
end

_spawnworkers!(::AbstractServer) = nothing

function _stopworkers!(server::Async)
    # Close channels to unblock any workers stuck on take!
    close(server.calls)
    close(server.replies)

    for t in server.workers
        try wait(t) catch end
    end
    empty!(server.workers)
end

_stopworkers!(::AbstractServer) = nothing

function _eventloop(server::Async)
    last_sweep = time()
    while server.core.running[]
        mg_mgr_poll(server.core.manager.ptr, server.core.poll_timeout)

        # Dispatch replies from workers back to C library
        local did_ws_send = false
        while isopen(server.replies) && isready(server.replies)
            res = take!(server.replies)
            conn = get(server.connections, res.id, nothing)
            if conn !== nothing
                if res.payload isa Response
                    _sendhttp!(conn, res.payload)
                    delete!(server.connections, res.id)
                else  # Message
                    try
                        _sendws!(conn, res.payload)
                        did_ws_send = true
                    catch e
                    _log_error("WebSocket send error component=websocket", e, catch_backtrace())
                    end
                end
            end
        end
        # Extra poll to flush mg_ws_send buffers immediately
        did_ws_send && mg_mgr_poll(server.core.manager.ptr, 1)
        # Periodic WS idle sweep
        if server.core.ws_idle_timeout > 0 && !isempty(server.core.ws_clients)
            now_t = time()
            if (now_t - last_sweep) >= 5.0
                _wsidlesweep!(server)
                last_sweep = now_t
            end
        end
        yield()
    end
end

function _workloop(server::Async)
    timeout = server.core.request_timeout
    try
        for req in server.calls     # blocks properly — no sleep needed
            if req.payload isa Request
                rid = _requestid(req.payload, server)
                res = try
                    if timeout > 0
                        _invoketimedhttp(server, req.payload, timeout)
                    else
                        _invokehttp(server, req.payload)
                    end
                catch e
                    _log_error("Handler error component=http uri=$(req.payload.uri)", e, catch_backtrace())
                    _handleerror(server, req.payload, e)
                end
                res = Response(res.status, _appendreqid(res.headers, rid), res.body)
                try isopen(server.replies) && put!(server.replies, Tagged(req.id, res)) catch end
            else  # Intent
                res = _invokews(server, req)
                try res !== nothing && isopen(server.replies) && put!(server.replies, res) catch end
            end
        end
    catch e
        e isa InvalidStateException || rethrow(e)
    end
end

_haspending(server::Async) = isready(server.calls) || isready(server.replies)
