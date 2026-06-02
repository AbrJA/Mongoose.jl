"""
    Typed request context and service injection.

    Per-request mutable state via `ctx!(req)`.
    App-level dependency injection via `provide!` / `inject`.
"""

# ctx! is defined here (operates on Request) but inject(req, key) is in server/core.jl
# because App is not yet defined at this include point.
