# Headers benchmarks — construction, lookup, and formatting.
using BenchmarkTools
using Mongoose

SUITE = BenchmarkGroup()

# --- Construction ---
SUITE["construct"] = BenchmarkGroup()

SUITE["construct"]["empty"] = @benchmarkable Pair{String,String}[]

SUITE["construct"]["5_pairs"] = @benchmarkable Pair{String,String}[
    "content-type" => "application/json",
    "authorization" => "Bearer token123",
    "accept" => "application/json",
    "user-agent" => "Mongoose.jl/0.3",
    "host" => "localhost:8080"
]

SUITE["construct"]["10_pairs"] = @benchmarkable Pair{String,String}[
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
]

# --- Lookup ---
SUITE["lookup"] = BenchmarkGroup()

const HEADERS_5 = Pair{String,String}[
    "content-type" => "application/json",
    "authorization" => "Bearer token123",
    "accept" => "application/json",
    "user-agent" => "Mongoose.jl/0.3",
    "host" => "localhost:8080"
]

const HEADERS_10 = Pair{String,String}[
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
]

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

SUITE["format"]["empty"]     = @benchmarkable Mongoose._formatheaders($(Pair{String,String}[]))
SUITE["format"]["5_headers"]  = @benchmarkable Mongoose._formatheaders($HEADERS_5)
SUITE["format"]["10_headers"] = @benchmarkable Mongoose._formatheaders($HEADERS_10)

# --- Response Construction ---
SUITE["response"] = BenchmarkGroup()

SUITE["response"]["raw_string"]       = @benchmarkable Response(Json, "{\"ok\":true}")
SUITE["response"]["typed_no_headers"]  = @benchmarkable Response(Html, "<h1>Hi</h1>")
SUITE["response"]["typed_with_headers"] = @benchmarkable Response(Html, "<h1>Hi</h1>"; headers=$HEADERS_5)
SUITE["response"]["headers_formatted"] = @benchmarkable Response(200, Mongoose._formatheaders($HEADERS_5), "{\"ok\":true}")
