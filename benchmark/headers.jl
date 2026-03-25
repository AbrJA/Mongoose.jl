"""
    Headers benchmarks — construction, lookup, and formatting.
"""
using BenchmarkTools
using Mongoose

const SUITE = BenchmarkGroup()

# --- Construction ---
SUITE["construct"] = BenchmarkGroup()

SUITE["construct"]["empty"] = @benchmarkable Headers()

SUITE["construct"]["5_pairs"] = @benchmarkable Headers([
    "content-type" => "application/json",
    "authorization" => "Bearer token123",
    "accept" => "application/json",
    "user-agent" => "Mongoose.jl/0.3",
    "host" => "localhost:8080"
])

SUITE["construct"]["10_pairs"] = @benchmarkable Headers([
    "content-type" => "application/json",
    "authorization" => "Bearer token123",
    "accept" => "application/json",
    "user-agent" => "Mongoose.jl/0.3",
    "host" => "localhost:8080",
    "connection" => "keep-alive",
    "cache-control" => "no-cache",
    "accept-encoding" => "gzip, deflate",
    "x-request-id" => "abc-123-def-456",
    "x-forwarded-for" => "192.168.1.1"
])

# --- Lookup ---
SUITE["lookup"] = BenchmarkGroup()

const HEADERS_5 = Headers([
    "content-type" => "application/json",
    "authorization" => "Bearer token123",
    "accept" => "application/json",
    "user-agent" => "Mongoose.jl/0.3",
    "host" => "localhost:8080"
])

const HEADERS_10 = Headers([
    "content-type" => "application/json",
    "authorization" => "Bearer token123",
    "accept" => "application/json",
    "user-agent" => "Mongoose.jl/0.3",
    "host" => "localhost:8080",
    "connection" => "keep-alive",
    "cache-control" => "no-cache",
    "accept-encoding" => "gzip, deflate",
    "x-request-id" => "abc-123-def-456",
    "x-forwarded-for" => "192.168.1.1"
])

# Hit (first element)
SUITE["lookup"]["5_hit_first"] = @benchmarkable get($HEADERS_5, "content-type", nothing)
# Hit (last element)
SUITE["lookup"]["5_hit_last"] = @benchmarkable get($HEADERS_5, "host", nothing)
# Miss
SUITE["lookup"]["5_miss"] = @benchmarkable get($HEADERS_5, "x-missing", nothing)

# Larger set
SUITE["lookup"]["10_hit_first"] = @benchmarkable get($HEADERS_10, "content-type", nothing)
SUITE["lookup"]["10_hit_last"] = @benchmarkable get($HEADERS_10, "x-forwarded-for", nothing)
SUITE["lookup"]["10_miss"] = @benchmarkable get($HEADERS_10, "x-missing", nothing)

# --- Formatting ---
SUITE["format"] = BenchmarkGroup()

SUITE["format"]["empty"] = @benchmarkable Mongoose._format_headers($(Headers()))
SUITE["format"]["5_headers"] = @benchmarkable Mongoose._format_headers($HEADERS_5)
SUITE["format"]["10_headers"] = @benchmarkable Mongoose._format_headers($HEADERS_10)

# --- Response Construction ---
SUITE["response"] = BenchmarkGroup()

SUITE["response"]["raw_string"] = @benchmarkable Response(200, Mongoose.ContentType.json, "{\"ok\":true}")
SUITE["response"]["typed_no_headers"] = @benchmarkable Response(Mongoose.Html, "<h1>Hi</h1>")
SUITE["response"]["typed_with_headers"] = @benchmarkable Response(Mongoose.Html, "<h1>Hi</h1>"; headers=$HEADERS_5)
SUITE["response"]["headers_obj"] = @benchmarkable Response(200, $HEADERS_5, "{\"ok\":true}")
