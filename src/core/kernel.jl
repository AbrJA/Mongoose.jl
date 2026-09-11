"""
    Kernel — transport-agnostic core of Mongoose.jl.

    Contains everything that does NOT depend on a server or an FFI transport:
    protocol types (Request, Response, Headers, formats, cookies, WS types,
    validation), the pluggable router, the middleware protocol + built-in
    middleware, and the URL/string utilities.

    This module is self-contained and can be loaded and tested without the C
    Mongoose library: `using Mongoose.Kernel`.

    The availability of this layer is what makes the transport replaceable —
    anything in `Kernel` can be exercised with pure Julia (see
    `Kernel.invoke_request` for the request→response seam).
"""
module Kernel

import JSON
using CodecZlib
using Base64

include("base.jl")          # AbstractRequest
include("strings.jl")       # URL/query/header utilities
include("formats.jl")       # AbstractFormat + MIME + encode/decode
include("status.jl")        # status_reason
include("request.jl")       # Request, Headers, form/multipart/query helpers
include("response.jl")      # Response, StreamResponse, Cookie
include("errors.jl")        # RouteError/ServerError/BindError, HTTPError hierarchy
include("ws_types.jl")      # Message, Intent, WsEndpoint, Tagged, WsConn
include("validation.jl")    # validate(), ValidationError

include("pipeline.jl")      # AbstractMiddleware, as_middleware, execute_pipeline
include("executor.jl")      # AbstractExecutor, SyncExecutor, submit!/start!/stop!

include("interface.jl")     # AbstractRouter protocol
include("transport.jl")     # AbstractTransport + capability traits
include("router.jl")        # Default Router (method map + ordered patterns)
include("groups.jl")        # RouteGroup + mount!
include("compiled.jl")      # Compiled frozen-route dispatch (freeze! table)
include("process.jl")       # invoke_request — the transport-agnostic seam

include("cors.jl")
include("ratelimit.jl")
include("auth.jl")
include("logger.jl")
include("health.jl")
include("metrics.jl")
include("security.jl")
include("compress.jl")
include("etag.jl")

export AbstractRequest, Request, Headers, context, form, header, query, body,
    multipart, MultipartFile,
    Response, StreamResponse, Cookie, bake, cookies, json, html, text, redirect,
    Plain, Html, Css, Js, Json, Xml, Binary, mime, content_type_pair, encode, decode,
    status_reason,
    RouteError, ServerError, BindError,
    HTTPError, error_status,
    BadRequestError, UnauthorizedError, PaymentRequiredError, ForbiddenError,
    NotFoundError, MethodNotAllowedError, NotAcceptableError, RequestTimeoutError,
    ConflictError, GoneError, LengthRequiredError, PreconditionFailedError,
    PayloadTooLargeError, URITooLongError, UnsupportedMediaTypeError,
    RangeNotSatisfiableError, ExpectationFailedError, ImATeapotError,
    UnprocessableEntityError, LockedError, FailedDependencyError, TooEarlyError,
    UpgradeRequiredError, PreconditionRequiredError, TooManyRequestsError,
    UnavailableForLegalReasonsError, InternalServerError,
    validate, ValidationError,
    Message, Intent, WsEndpoint, WsConn, Tagged,
    AbstractRouter, Router, MethodMap, RouteResult, Matched, NoMatch, WrongMethod,
    SingleEndpoint, matchroute, hasroute,
    get_handler, get_endpoint, set_handler!, haswsroutes, ws_endpoint,
    route!, ws!, group, group!, RouteGroup, mount!, post!, patch!, options!, head!,
    Endpoint, error_response, invoke_request, RequestContext, freeze!, isfrozen, terminal_for,
    AbstractMiddleware, PathFilter, execute_pipeline, FunctionMiddleware, as_middleware,
    AbstractExecutor, SyncExecutor, FakeExecutor, run!, submit!, start!, stop!,
    AbstractTransport, supportsws, supportstls, supportsstream,
    Cors, Bearer, ApiKey, BasicAuth, RateLimit, Compress, Logger, Health,
    PrometheusMetrics, SecurityHeaders, Etag,
    cors, ratelimit, bearer, apikey, basicauth, logger, health, metrics, security, compress, etag,
    parse_query, strip_query, format_headers, sanitize_header_value, to_lower, url_decode

end # module Kernel
