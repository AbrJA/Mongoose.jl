"""
    Request logging middleware.
    Logs method, URI, status, and response time for each request.
    Supports plain text and structured (JSON) output formats.
"""

struct Logger <: AbstractMiddleware
    threshold_ns::Int
    output::IO
    structured::Bool
end

function (mw::Logger)(request::AbstractRequest, params::Vector{Any}, next)
    t0 = time_ns()
    response = next()
    elapsed_ns = time_ns() - t0

    if elapsed_ns >= mw.threshold_ns
        elapsed_ms = elapsed_ns / 1_000_000
        status = response isa Response ? response.status : 0

        if mw.structured
            # JSON structured log line (no dependency — manual formatting)
            method = uppercase(String(request.method))
            uri = request.uri
            println(mw.output,
                "{\"method\":\"", method,
                "\",\"uri\":\"", uri,
                "\",\"status\":", status,
                ",\"duration_ms\":", round(elapsed_ms; digits=2),
                ",\"ts\":\"", Libc.strftime("%Y-%m-%dT%H:%M:%S", time()),
                "\"}")
        else
            println(mw.output, uppercase(String(request.method)), " ", request.uri, " → ", status, " (", round(elapsed_ms; digits=2), "ms)")
        end
    end

    return response
end

"""
    logger(; threshold_ms=0, output=stderr, structured=false)

Create a request-logging middleware.

# Keyword Arguments
- `threshold_ms::Int`: Only log requests slower than this (default: `0` = log all).
- `output::IO`: IO stream for log output (default: `stderr`).
- `structured::Bool`: If `true`, emit one JSON object per line (default: `false`).

# Example
```julia
use!(server, logger())                         # plain text, all requests
use!(server, logger(threshold_ms=100))         # only slow requests
use!(server, logger(structured=true))          # JSON structured logs
```
"""
logger(; threshold_ms::Int=0, output::IO=stderr, structured::Bool=false) = Logger(threshold_ms * 1_000_000, output, structured)
