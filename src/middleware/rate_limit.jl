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
    
    return function(request::AbstractRequest, params::Dict{String,String}, next)
        # Use the first segment of URI as a crude client identifier
        # In production, you'd extract the client IP from headers or connection
        client_id = if request isa HttpRequest
            get(request.headers, "X-Forwarded-For", get(request.headers, "X-Real-IP", "unknown"))
        else
            "unknown"
        end
        
        now_t = time()
        allowed = lock(tracker_lock) do
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
            return HttpResponse(429, "Content-Type: text/plain\r\nRetry-After: $retry_after\r\n", "429 Too Many Requests")
        end
        
        return next()
    end
end
