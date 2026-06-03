"""
    Typed request context and service injection.

    Per-request mutable state via `context(req)`.
    App-level dependency injection via `service!` / `service`.
"""

# context() is defined here (operates on Request) but service(req, key) is in server/core.jl
# because App is not yet defined at this include point.
