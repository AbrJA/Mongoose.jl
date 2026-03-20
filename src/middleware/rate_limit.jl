"""
    Rate limiting middleware using a token-bucket algorithm.
    Tracks requests per client IP with automatic cleanup.
"""

"""
    rate_limit_middleware(; max_requests, window_seconds)

Create a rate-limiting middleware using a simple fixed-window counter.
Returns 429 Too Many Requests when the limit is exceeded.

# Keyword Arguments
- `max_requests::Int`: Maximum requests allowed per window (default: `100`).
- `window_seconds::Int`: Time window duration in seconds (default: `60`).

# Example
```julia
use!(server, rate_limit_middleware(max_requests=50, window_seconds=30))
```
"""
function rate_limit_middleware(; max_requests::Int=100, window_seconds::Int=60)
    # Per-IP request tracking: ip → (count, window_start_time)
    tracker = Dict{String, Tuple{Int, Float64}}()
    tracker_lock = ReentrantLock()
    last_cleanup = Ref(time())
    cleanup_interval = max(window_seconds * 2.0, 60.0)

    return function(request::AbstractRequest, params::Vector{Any}, next)
        client_id = if request isa Request
            get(request.headers, "x-forwarded-for", get(request.headers, "x-real-ip", "unknown"))
        elseif request isa ViewRequest
            h = header(request, "X-Forwarded-For")
            h === nothing ? (let h2 = header(request, "X-Real-IP"); h2 === nothing ? "unknown" : h2 end) : h
        else
            "unknown"
        end

        now_t = time()
        allowed = lock(tracker_lock) do
            # Periodic cleanup of stale entries
            if (now_t - last_cleanup[]) > cleanup_interval
                for (k, v) in collect(tracker)
                    if (now_t - v[2]) > window_seconds
                        delete!(tracker, k)
                    end
                end
                last_cleanup[] = now_t
            end

            entry = get(tracker, client_id, nothing)

            if entry === nothing || (now_t - entry[2]) > window_seconds
                # New window
                tracker[client_id] = (1, now_t)
                return true
            else
                count, start = entry
                if count >= max_requests
                    return false
                else
                    tracker[client_id] = (count + 1, start)
                    return true
                end
            end
        end

        if !allowed
            retry_after = string(window_seconds)
            return Response(429, "Content-Type: text/plain\r\nRetry-After: $retry_after\r\n", "429 Too Many Requests")
        end

        return next()
    end
end
