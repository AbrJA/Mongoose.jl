"""
    Rate limiting middleware using a fixed-window counter with sharded locks.

    Tracks requests per bucket key with automatic cleanup, using N shards
    (each with its own lock) to reduce contention under high concurrency.

    Buckets are keyed by a user-supplied `key_fn(request) -> String`, or by a
    default that keys on the request's transport-provided remote address
    (per-client host; `X-Forwarded-For`/`X-Real-IP` are only trusted when
    `trust_proxies=true`, since reading proxy headers directly is a spoofing
    vector when the app is exposed to clients).
"""

const _RATE_LIMIT_SHARDS = 16

struct _RateShard
    tracker::Dict{String, Tuple{Int, Float64}}
    lock::Threads.SpinLock
    last_cleanup::Base.RefValue{Float64}
end

struct RateLimit{F} <: AbstractMiddleware
    max_requests::Int
    window_seconds::Int
    cleanup_interval::Float64
    shards::Vector{_RateShard}
    key_fn::F                   # (Request) -> bucket key
    trust_proxies::Bool
end

@doc """
    RateLimit — fixed-window rate limiting middleware with sharded locks.

    Tracks requests per bucket key with automatic cleanup, using N shards
    (each with its own lock) to reduce contention under high concurrency.

    Buckets are keyed by a user-supplied `key_fn(request) -> String`, or by a
    default that keys on the request's transport-provided remote address;
    `X-Forwarded-For`/`X-Real-IP` are only trusted when `trust_proxies=true`
    (reading proxy headers directly is a spoofing vector when the app is
    exposed to clients).
""" RateLimit

@inline function _shard(mw::RateLimit, key::String)
    return mw.shards[mod1(hash(key), length(mw.shards))]
end

# Default bucket key: first X-Forwarded-For entry, or X-Real-IP, when proxy
# headers are trusted (for deployments behind an overwriting proxy); otherwise
# the request's transport-provided remote address (per-client host). Falls back
# to a shared "unknown" bucket only when no address is available.
function _default_key_fn(trust::Bool)
    return function (request)
        if trust
            h = get(request.headers, "x-forwarded-for", nothing)
            if h !== nothing
                ci = findfirst(',', h)
                return ci !== nothing ? String(strip(h[1:ci-1])) : String(strip(h))
            end
            h2 = get(request.headers, "x-real-ip", nothing)
            h2 !== nothing && return String(strip(h2))
        end
        addr = request.remote_addr
        addr === nothing && return "unknown"
        return addr
    end
end

function (mw::RateLimit)(request::Request, next::Function)
    client_id = mw.key_fn(request)

    shard = _shard(mw, client_id)
    now_t = time()

    # --- Phase 1: fast path — O(1) dict lookup + increment under the lock.
    needs_cleanup = false
    lock(shard.lock)
    allowed = try
        needs_cleanup = (now_t - shard.last_cleanup[]) > mw.cleanup_interval
        if needs_cleanup
            shard.last_cleanup[] = now_t  # reset timer now, cleanup happens below
        end

        entry = get(shard.tracker, client_id, nothing)

        if entry === nothing || (now_t - entry[2]) > mw.window_seconds
            shard.tracker[client_id] = (1, now_t)
            true
        else
            count, start = entry
            if count >= mw.max_requests
                false
            else
                shard.tracker[client_id] = (count + 1, start)
                true
            end
        end
    finally
        unlock(shard.lock)
    end

    # --- Phase 2: amortized cleanup —
    if needs_cleanup
        lock(shard.lock)
        try
            for (k, v) in collect(shard.tracker)
                if (now_t - v[2]) > mw.window_seconds
                    delete!(shard.tracker, k)
                end
            end
        finally
            unlock(shard.lock)
        end
    end

    if !allowed
        retry_after = string(mw.window_seconds)
        return Response(Plain, "Too Many Requests"; status=429, headers=["Retry-After" => retry_after])
    end

    return next()
end

"""
    ratelimit(; max_requests, window_seconds, trust_proxies, key_fn)

Create a rate-limiting middleware using a sharded fixed-window counter.
Returns 429 Too Many Requests when the limit is exceeded.

Uses $(_RATE_LIMIT_SHARDS) independent shards internally to minimize lock contention.

# Keyword Arguments
- `max_requests::Int`: Maximum requests allowed per window (default: `100`).
- `window_seconds::Int`: Time window duration in seconds (default: `60`).
- `trust_proxies::Bool`: Trust `X-Forwarded-For`/`X-Real-IP` for the default
  bucket key (default: `false`). Enable only behind a proxy that overwrites
  these headers; otherwise clients can spoof their bucket. Without it the
  default key is the request's remote address (per-client host).
- `key_fn::Function`: Custom bucket key `(Request) -> String`, overriding the
  default IP-based key (e.g. an API key extracted from the request).

# Example
```julia
use!(server, ratelimit(max_requests=50, window_seconds=30))
use!(server, ratelimit(max_requests=100, key_fn=req -> apikey(req)))
```
"""
function ratelimit(; max_requests::Int=100, window_seconds::Int=60,
                   trust_proxies::Bool=false, key_fn::Union{Function,Nothing}=nothing)
    shards = [_RateShard(Dict{String,Tuple{Int,Float64}}(), Threads.SpinLock(), Ref(time())) for _ in 1:_RATE_LIMIT_SHARDS]
    key = key_fn === nothing ? _default_key_fn(trust_proxies) : key_fn
    return RateLimit(
        max_requests, window_seconds,
        max(window_seconds * 2.0, 60.0),
        shards, key, trust_proxies
    )
end