"""
    Request logging middleware.
    Logs method, URI, status, and response time for each request.
    Uses `time_ns()` for minimal overhead (~20ns per call).
"""

struct Logger <: Middleware
    threshold_ns::Int
    output::IO
end

function (mw::Logger)(request::AbstractRequest, params::Vector{Any}, next)
    t0 = time_ns()
    response = next()
    elapsed_ns = time_ns() - t0

    if elapsed_ns >= mw.threshold_ns
        elapsed_ms = elapsed_ns / 1_000_000
        status = response isa AbstractResponse ? response.status : 0
        println(mw.output, uppercase(String(request.method)), " ", request.uri, " → ", status, " (", round(elapsed_ms; digits=2), "ms)")
    end

    return response
end

"""
    logger(; threshold_ms=0, output=stderr)

Create a request-logging middleware. Disabled by default — only active when added via `use!`.

# Keyword Arguments
- `threshold_ms::Int`: Only log requests slower than this (default: `0` = log all).
- `output::IO`: IO stream for log output (default: `stderr`).

# Example
```julia
use!(server, logger())                     # log all requests
use!(server, logger(threshold_ms=100))     # only log slow requests (>100ms)
```
"""
logger(; threshold_ms::Int=0, output::IO=stderr) = Logger(threshold_ms * 1_000_000, output)
