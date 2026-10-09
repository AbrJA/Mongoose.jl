"""
    Health check middleware for cloud-native deployments.
    Provides `/healthz`, `/readyz`, and `/livez` endpoints for Kubernetes.
"""

"""
    Health — Health check middleware for cloud-native deployments.
    Intercepts the configured probe paths before any other middleware.
"""
struct Health{H,R,L} <: AbstractMiddleware
    health_check::H
    ready_check::R
    live_check::L
    health_path::Union{Nothing,String}
    ready_path::Union{Nothing,String}
    live_path::Union{Nothing,String}
end

# Functor (not a closure) so the kwargs stay concrete: Julia does not
# specialize on `Function`-typed arguments, which would widen `Health` and
# break the trim verifier.
struct _HealthOK end
(::_HealthOK)() = true

"""
    health(; health_check, ready_check, live_check,
             health_path="/healthz", ready_path="/readyz", live_path="/livez")

Create a health check middleware for cloud-native deployments.

# Keyword Arguments
- `health_check`: zero-arg callable returning `true` if the service is healthy (default: always true)
- `ready_check`: zero-arg callable returning `true` if the service is ready for traffic (default: always true)
- `live_check`: zero-arg callable returning `true` if the service is alive (default: always true)
- `health_path`, `ready_path`, `live_path`: probe paths; `nothing` disables an
  endpoint (e.g. `health_path="/health"` for a single combined probe)

# Endpoints
- `GET /healthz`: Overall health status (combines all checks)
- `GET /readyz`: Readiness for traffic (load balancers)
- `GET /livez`: Liveness check (process alive)

# Example
```julia
server = use(server, health(
    health_check = () -> check_database(),
    ready_check = () -> check_dependencies(),
    live_check = () -> true,  # Process is always alive if running
    health_path = "/health",  # custom path; ready_path=nothing disables /readyz
))
```
"""
function health(;
    health_check = _HealthOK(),
    ready_check = _HealthOK(),
    live_check = _HealthOK(),
    health_path::Union{Nothing,AbstractString} = "/healthz",
    ready_path::Union{Nothing,AbstractString} = "/readyz",
    live_path::Union{Nothing,AbstractString} = "/livez"
)
    return Health(health_check, ready_check, live_check,
                  _probe_path(health_path), _probe_path(ready_path), _probe_path(live_path))
end

@inline _probe_path(p::Nothing) = nothing
@inline _probe_path(p::AbstractString) = String(p)

function (mw::Health)(request::Request, next::Function)
    uri = request.uri

    if mw.health_path !== nothing && uri == mw.health_path
        healthy = mw.health_check()
        ready = mw.ready_check()
        alive = mw.live_check()

        status = healthy && ready && alive ? 200 : 503

        io = IOBuffer(sizehint = 64)
        print(io, "status: ", status == 200 ? "healthy" : "unhealthy",
              "\nchecks: health=", healthy ? "true" : "false",
              ", ready=", ready ? "true" : "false",
              ", alive=", alive ? "true" : "false", '\n')
        return Response(Plain, String(take!(io)); status=status)

    elseif mw.ready_path !== nothing && uri == mw.ready_path
        ready = mw.ready_check()
        status = ready ? 200 : 503
        return Response(Plain, ready ? "status: ready\n" : "status: not ready\n";
                        status=status)

    elseif mw.live_path !== nothing && uri == mw.live_path
        alive = mw.live_check()
        status = alive ? 200 : 503
        return Response(Plain, alive ? "status: alive\n" : "status: dead\n";
                        status=status)
    end

    return next()
end

Base.show(io::IO, ::Health) = print(io, "Health()")
