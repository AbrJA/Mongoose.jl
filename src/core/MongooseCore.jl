"""
    MongooseCore — transport-agnostic core of Mongoose.jl.

    Contains everything that does NOT depend on a server or an FFI transport:
    protocol types (Request, Response, Headers, formats, cookies, WS types,
    validation), the pluggable router, the middleware protocol + built-in
    middleware, and the URL/string utilities.

    This module is self-contained and can be loaded and tested without the C
    Mongoose library: `using Mongoose.MongooseCore`.

    The availability of this layer is what makes the transport replaceable —
    anything in `MongooseCore` can be exercised with pure Julia (see
    `MongooseCore.Pipeline` for the request→response seam).
"""
module MongooseCore

import JSON
using CodecZlib
using Base64

include("base.jl")          # AbstractRequest
include("errors.jl")        # RouteError, ServerError, BindError
include("strings.jl")       # URL/query/header utilities
include("formats.jl")       # AbstractFormat + MIME + encode/decode
include("status.jl")        # status_reason
include("request.jl")       # Request, Headers, form/multipart/query helpers
include("response.jl")      # Response, StreamResponse, Cookie
include("ws_types.jl")      # Message, Intent, WsEndpoint, Tagged, WsConn
include("validation.jl")    # validate(), ValidationError

include("pipeline.jl")      # AbstractMiddleware, before/after, execute_pipeline
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

export AbstractRequest, Request, Headers, context, form, header, query, body,
    multipart, MultipartFile,
    Response, StreamResponse, Cookie, bake, cookies, json, html, text, redirect,
    Plain, Html, Css, Js, Json, Xml, Binary, mime, content_type_pair, encode, decode,
    status_reason,
    RouteError, ServerError, BindError,
    validate, ValidationError,
    Message, Intent, WsEndpoint, WsConn, Tagged,
    AbstractRouter, Router, RouteMatch, MethodMap, dispatch_route, match_route_exact,
    get_handler, get_endpoint, set_handler!, has_ws_routes, ws_endpoint, route_count,
    route!, ws!, group, group!, RouteGroup, mount!, post!, patch!, options!, head!,
    Endpoint, error_response, invoke_request, freeze!, isfrozen, terminal_for,
    AbstractMiddleware, before, after, PathFilter, execute_pipeline, FunctionMiddleware, as_middleware,
    AbstractExecutor, SyncExecutor, submit!, start!, stop!,
    AbstractTransport, supports_websocket, supports_tls, supports_streaming,
    Cors, Bearer, ApiKey, BasicAuth, RateLimit, Compress, Logger, Health,
    PrometheusMetrics, SecurityHeaders,
    cors, ratelimit, bearer, apikey, basicauth, logger, health, metrics, security, compress,
    parse_query, strip_query, format_headers, sanitize_header_value, to_lower, url_decode

end # module MongooseCore
