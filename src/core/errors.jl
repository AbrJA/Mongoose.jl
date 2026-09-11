"""
    Custom exception types for Mongoose.jl.
    Structured hierarchy with error codes for machine-readable error handling.
"""
abstract type MongooseError <: Exception end

"""
    RouteError — Route registration or matching failure.
"""
struct RouteError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::RouteError) = print(io, "RouteError: ", e.msg)

"""
    ServerError — Server operation failure (initialization, memory, config).
"""
struct ServerError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::ServerError) = print(io, "ServerError: ", e.msg)

"""
    BindError — Failed to bind to address/port.
"""
struct BindError <: MongooseError
    msg::String
end
Base.showerror(io::IO, e::BindError) = print(io, "BindError: ", e.msg)

# ── HTTPError: status-carrying exceptions ────────────────────────────────────
#
# A single parametric struct, `HTTPError{status}`, where the HTTP status code
# is a compile-time constant embedded in the type. This makes the wire status
# free to extract (`e isa HTTPError{T} → T`, constant-folded), lets users
# dispatch on the exact type (`onerror!(app, NotFoundError) do req, e ...`),
# and keeps the "carrier" minimal — no union fields, no boxing.

"""
    HTTPError{status} <: Exception

Exception that maps to an HTTP error response. The status code is a
compile-time constant type parameter, so `errorstatus(e)` is free and
`onerror!(app, NotFoundError)` (or `onerror!(app, HTTPError{404})`) registers a
handler for exactly that status.

Throw it inside a handler (or middleware) to signal a non-200 reply with a
custom message:

```julia
get!(app, "/users/:id::Int") do req, id
    id in 1:999 || throw(NotFoundError("user \$id not found"))
    json((id=id,))
end
```

A thrown `HTTPError` is mapped to
`Response(status, headers, message)` automatically at the transport boundary,
unless a more specific `onerror!` handler (checked first) or a custom
`onerror!(app, status, …)` error page takes precedence.

Named aliases are provided for common statuses: `BadRequestError`,
`UnauthorizedError`, `ForbiddenError`, `NotFoundError`, `MethodNotAllowedError`,
`RequestTimeoutError`, `ConflictError`, `PayloadTooLargeError`,
`UnsupportedMediaTypeError`, `UnprocessableEntityError`, `TooManyRequestsError`,
`InternalServerError`, …
"""
struct HTTPError{status} <: Exception
    message::String
    headers::Headers
end

HTTPError{status}(message::AbstractString) where {status} =
    HTTPError{status}(String(message), Headers())
HTTPError{status}() where {status} =
    HTTPError{status}(statusreason(status), Headers())

"""
    errorstatus(e::HTTPError) → Int

The HTTP status code carried by `e` (the compile-time type parameter).
"""
@inline errorstatus(::HTTPError{status}) where {status} = status

function Base.showerror(io::IO, e::HTTPError{status}) where {status}
    reason = statusreason(status)
    if isempty(reason)
        print(io, "HTTPError ", status, ": ", e.message)
    else
        print(io, reason, " (", status, "): ", e.message)
    end
end

Base.show(io::IO, e::HTTPError{status}) where {status} =
    print(io, "HTTPError{", status, "}(", repr(e.message), ")")

# ── Named status aliases (4xx client errors) ────────────────────────────────

const BadRequestError = HTTPError{400}
const UnauthorizedError = HTTPError{401}
const PaymentRequiredError = HTTPError{402}
const ForbiddenError = HTTPError{403}
const NotFoundError = HTTPError{404}
const MethodNotAllowedError = HTTPError{405}
const NotAcceptableError = HTTPError{406}
const RequestTimeoutError = HTTPError{408}
const ConflictError = HTTPError{409}
const GoneError = HTTPError{410}
const LengthRequiredError = HTTPError{411}
const PreconditionFailedError = HTTPError{412}
const PayloadTooLargeError = HTTPError{413}
const URITooLongError = HTTPError{414}
const UnsupportedMediaTypeError = HTTPError{415}
const RangeNotSatisfiableError = HTTPError{416}
const ExpectationFailedError = HTTPError{417}
const ImATeapotError = HTTPError{418}
const UnprocessableEntityError = HTTPError{422}
const LockedError = HTTPError{423}
const FailedDependencyError = HTTPError{424}
const TooEarlyError = HTTPError{425}
const UpgradeRequiredError = HTTPError{426}
const PreconditionRequiredError = HTTPError{428}
const TooManyRequestsError = HTTPError{429}
const UnavailableForLegalReasonsError = HTTPError{451}

# ── Named status aliases (5xx server errors) ────────────────────────────────

const InternalServerError = HTTPError{500}