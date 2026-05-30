"""
    Typed request context and service container.

    Provides dependency injection via a `ServiceRegistry` attached to the server,
    and per-request typed context access.
"""

"""
    ServiceRegistry — Application-level dependency injection container.

    Services are registered as factories (lazy singletons) or direct values.
    Thread-safe: uses a lock only during first initialization of each service.
"""
struct ServiceRegistry
    factories::Dict{Symbol,Function}
    instances::Dict{Symbol,Any}
    lock::ReentrantLock
end

ServiceRegistry() = ServiceRegistry(Dict{Symbol,Function}(), Dict{Symbol,Any}(), ReentrantLock())

"""
    register!(registry, key, factory)

Register a service factory. The factory is called once (lazy singleton).
"""
function register!(registry::ServiceRegistry, key::Symbol, factory::Function)
    registry.factories[key] = factory
    return registry
end

"""
    register!(registry, key, instance)

Register a pre-created service instance directly.
"""
function register!(registry::ServiceRegistry, key::Symbol, instance)
    registry.instances[key] = instance
    return registry
end

"""
    service(registry, key) → Any

Retrieve a service by key. Creates it from factory on first access (thread-safe).
"""
function service(registry::ServiceRegistry, key::Symbol)
    # Fast path: already initialized
    inst = get(registry.instances, key, nothing)
    inst !== nothing && return inst

    # Slow path: initialize under lock
    lock(registry.lock) do
        inst = get(registry.instances, key, nothing)
        inst !== nothing && return inst
        factory = get(registry.factories, key, nothing)
        factory === nothing && error("Service :$key not registered")
        instance = factory()
        registry.instances[key] = instance
        return instance
    end
end

"""
    service(req, key) → Any

Access a service from a request's context (shortcut for handler use).
Requires the server to have attached its `ServiceRegistry` to the request context.
"""
function service(req::Request, key::Symbol)
    ctx = context!(req)
    registry = get(ctx, :_services, nothing)
    registry === nothing && error("No ServiceRegistry attached to request context. Use `services=` when creating the server.")
    return service(registry::ServiceRegistry, key)
end
