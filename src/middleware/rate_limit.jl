"""
    Rate limiting middleware using a fixed-window counter with sharded locks.
    Tracks requests per client IP with automatic cleanup.
    Uses N shards (each with its own lock) to reduce contention under high concurrency.
"""

const _RATE_LIMIT_SHARDS = 16

struct _RateShard
    tracker::Dict{String, Tuple{Int, Float64}}
    lock::ReentrantLock
    last_cleanup::Base.RefValue{Float64}
end

struct RateLimit <: AbstractMiddleware
    max_requests::Int
    window_seconds::Int
    cleanup_interval::Float64
    shards::Vector{_RateShard}
end

@inline function _shard(mw::RateLimit, key::String)
    h = hash(key)
    idx = (h % length(mw.shards)) + 1
    return mw.shards[idx]
end

function (mw::RateLimit)(request::AbstractRequest, params::Vector{Any}, next)
    client_id = let h = get(request.headers, "x-forwarded-for", nothing)
        if h !== nothing
            ci = findfirst(',', h)
            ci !== nothing ? String(strip(h[1:ci-1])) : String(strip(h))
        else
            h2 = get(request.headers, "x-real-ip", nothing)
            h2 !== nothing ? String(strip(h2)) : "unknown"
        end
    end

    shard = _shard(mw, client_id)
    now_t = time()

    allowed = lock(shard.lock) do
        if (now_t - shard.last_cleanup[]) > mw.cleanup_interval
            for (k, v) in collect(shard.tracker)
                if (now_t - v[2]) > mw.window_seconds
                    delete!(shard.tracker, k)
                end
            end
            shard.last_cleanup[] = now_t
        end

        entry = get(shard.tracker, client_id, nothing)

        if entry === nothing || (now_t - entry[2]) > mw.window_seconds
            shard.tracker[client_id] = (1, now_t)
            return true
        else
            count, start = entry
            if count >= mw.max_requests
                return false
            else
                shard.tracker[client_id] = (count + 1, start)
                return true
            end
        end
    end

    if !allowed
        retry_after = string(mw.window_seconds)
        return Response(429, content_type(Text) * "Retry-After: $retry_after\r\n", "429 Too Many Requests")
    end

    return next()
end

"""
    rate_limit(; max_requests, window_seconds)

Create a rate-limiting middleware using a sharded fixed-window counter.
Returns 429 Too Many Requests when the limit is exceeded.

Uses $(_RATE_LIMIT_SHARDS) independent shards internally to minimize lock contention.

# Keyword Arguments
- `max_requests::Int`: Maximum requests allowed per window (default: `100`).
- `window_seconds::Int`: Time window duration in seconds (default: `60`).

# Example
```julia
plug!(server, rate_limit(max_requests=50, window_seconds=30))
```
"""
function rate_limit(; max_requests::Int=100, window_seconds::Int=60)
    shards = [_RateShard(Dict{String,Tuple{Int,Float64}}(), ReentrantLock(), Ref(time())) for _ in 1:_RATE_LIMIT_SHARDS]
    return RateLimit(
        max_requests, window_seconds,
        max(window_seconds * 2.0, 60.0),
        shards
    )
end
