"""
    Rate limiting middleware using a fixed-window counter.
    Tracks requests per client IP with automatic cleanup.
"""

struct RateLimit <: Middleware
    max_requests::Int
    window_seconds::Int
    tracker::Dict{String, Tuple{Int, Float64}}
    tracker_lock::ReentrantLock
    last_cleanup::Base.RefValue{Float64}
    cleanup_interval::Float64
end

function (mw::RateLimit)(request::AbstractRequest, params::Vector{Any}, next)
    client_id = let h = header(request, "X-Forwarded-For")
        h !== nothing ? h : let h2 = header(request, "X-Real-IP")
            h2 !== nothing ? h2 : "unknown"
        end
    end

    now_t = time()
    allowed = lock(mw.tracker_lock) do
        if (now_t - mw.last_cleanup[]) > mw.cleanup_interval
            for (k, v) in collect(mw.tracker)
                if (now_t - v[2]) > mw.window_seconds
                    delete!(mw.tracker, k)
                end
            end
            mw.last_cleanup[] = now_t
        end

        entry = get(mw.tracker, client_id, nothing)

        if entry === nothing || (now_t - entry[2]) > mw.window_seconds
            mw.tracker[client_id] = (1, now_t)
            return true
        else
            count, start = entry
            if count >= mw.max_requests
                return false
            else
                mw.tracker[client_id] = (count + 1, start)
                return true
            end
        end
    end

    if !allowed
        retry_after = string(mw.window_seconds)
        return Response(429, ContentType.text * "Retry-After: $retry_after\r\n", "429 Too Many Requests")
    end

    return next()
end

"""
    rate_limit(; max_requests, window_seconds)

Create a rate-limiting middleware using a simple fixed-window counter.
Returns 429 Too Many Requests when the limit is exceeded.

# Keyword Arguments
- `max_requests::Int`: Maximum requests allowed per window (default: `100`).
- `window_seconds::Int`: Time window duration in seconds (default: `60`).

# Example
```julia
use!(server, rate_limit(max_requests=50, window_seconds=30))
```
"""
function rate_limit(; max_requests::Int=100, window_seconds::Int=60)
    return RateLimit(
        max_requests, window_seconds,
        Dict{String, Tuple{Int, Float64}}(),
        ReentrantLock(),
        Ref(time()),
        max(window_seconds * 2.0, 60.0)
    )
end
