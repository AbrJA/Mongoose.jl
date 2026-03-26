"""
    Health check middleware for cloud-native deployments.
    Provides `/healthz`, `/readyz`, and `/livez` endpoints for Kubernetes.
"""

struct HealthMiddleware <: AbstractMiddleware
    health_check::Function
    ready_check::Function
    live_check::Function
end

"""
    health(; health_check, ready_check, live_check)

Create a health check middleware for cloud-native deployments.

# Keyword Arguments
- `health_check::Function`: Function that returns `true` if the service is healthy (default: always true)
- `ready_check::Function`: Function that returns `true` if the service is ready to accept traffic (default: always true)
- `live_check::Function`: Function that returns `true` if the service is alive (default: always true)

# Endpoints
- `GET /healthz`: Overall health status (combines all checks)
- `GET /readyz`: Readiness for traffic (load balancers)
- `GET /livez`: Liveness check (process alive)

# Example
```julia
use!(server, health(
    health_check = () -> check_database(),
    ready_check = () -> check_dependencies(),
    live_check = () -> true  # Process is always alive if running
))
```
"""
function health(;
    health_check::Function = () -> true,
    ready_check::Function = () -> true,
    live_check::Function = () -> true
)
    return HealthMiddleware(health_check, ready_check, live_check)
end

function (mw::HealthMiddleware)(request::AbstractRequest, params::Vector{Any}, next)
    uri = request.uri

    if uri == "/healthz"
        healthy = mw.health_check()
        ready = mw.ready_check()
        alive = mw.live_check()

        status = healthy && ready && alive ? 200 : 503

        # Simple response without timestamp for now
        body = "status: $(status == 200 ? "healthy" : "unhealthy")\nchecks: health=$healthy, ready=$ready, alive=$alive\n"
        return Response(status, ContentType.text, body)

    elseif uri == "/readyz"
        ready = mw.ready_check()
        status = ready ? 200 : 503
        body = "status: $(ready ? "ready" : "not ready")\n"
        return Response(status, ContentType.text, body)

    elseif uri == "/livez"
        alive = mw.live_check()
        status = alive ? 200 : 503
        body = "status: $(alive ? "alive" : "dead")\n"
        return Response(status, ContentType.text, body)
    end

    # Not a health endpoint, continue to next middleware/handler
    return next()
end
