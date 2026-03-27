"""
    Router benchmarks — registration, matching, and dispatch.
"""
using BenchmarkTools
using Mongoose

const SUITE = BenchmarkGroup()

# --- Route Registration ---
SUITE["register"] = BenchmarkGroup()

SUITE["register"]["static_5"] = @benchmarkable begin
    r = Router()
    route!(r, :get, "/", req -> Response(200, "", ""))
    route!(r, :get, "/about", req -> Response(200, "", ""))
    route!(r, :get, "/contact", req -> Response(200, "", ""))
    route!(r, :post, "/login", req -> Response(200, "", ""))
    route!(r, :post, "/signup", req -> Response(200, "", ""))
end

SUITE["register"]["dynamic_5"] = @benchmarkable begin
    r = Router()
    route!(r, :get, "/users/:id::Int", (req, id) -> Response(200, "", ""))
    route!(r, :get, "/users/:id::Int/posts", (req, id) -> Response(200, "", ""))
    route!(r, :post, "/users/:id::Int/posts", (req, id) -> Response(200, "", ""))
    route!(r, :get, "/items/:slug", (req, slug) -> Response(200, "", ""))
    route!(r, :delete, "/items/:slug", (req, slug) -> Response(200, "", ""))
end

# --- Route Matching ---
SUITE["match"] = BenchmarkGroup()

# Pre-build a router with realistic routes
function build_router()
    r = Router()
    route!(r, :get, "/", req -> Response(200, "", ""))
    route!(r, :get, "/about", req -> Response(200, "", ""))
    route!(r, :get, "/health", req -> Response(200, "", ""))
    route!(r, :get, "/api/v1/users", req -> Response(200, "", ""))
    route!(r, :get, "/api/v1/users/:id::Int", (req, id) -> Response(200, "", ""))
    route!(r, :get, "/api/v1/users/:id::Int/posts", (req, id) -> Response(200, "", ""))
    route!(r, :post, "/api/v1/users", req -> Response(200, "", ""))
    route!(r, :put, "/api/v1/users/:id::Int", (req, id) -> Response(200, "", ""))
    route!(r, :delete, "/api/v1/users/:id::Int", (req, id) -> Response(200, "", ""))
    route!(r, :get, "/api/v1/posts/:id::Int", (req, id) -> Response(200, "", ""))
    return r
end

const ROUTER = build_router()

# Fixed route (fast path)
SUITE["match"]["fixed_root"] = @benchmarkable Mongoose.match_route($ROUTER, :get, "/")
SUITE["match"]["fixed_about"] = @benchmarkable Mongoose.match_route($ROUTER, :get, "/about")
SUITE["match"]["fixed_deep"] = @benchmarkable Mongoose.match_route($ROUTER, :get, "/api/v1/users")

# Dynamic route (trie traversal + parameter parsing)
SUITE["match"]["dynamic_1param"] = @benchmarkable Mongoose.match_route($ROUTER, :get, "/api/v1/users/42")
SUITE["match"]["dynamic_deep"] = @benchmarkable Mongoose.match_route($ROUTER, :get, "/api/v1/users/42/posts")

# Miss (404)
SUITE["match"]["miss_shallow"] = @benchmarkable Mongoose.match_route($ROUTER, :get, "/nonexistent")
SUITE["match"]["miss_deep"] = @benchmarkable Mongoose.match_route($ROUTER, :get, "/api/v1/missing/path")

# --- Dispatch (full pipeline) ---
SUITE["dispatch"] = BenchmarkGroup()

const REQ_ROOT = Request(:get, "/", "", Headers(), "", Dict{Symbol,Any}())
const REQ_USERS = Request(:get, "/api/v1/users/42", "", Headers(), "", Dict{Symbol,Any}())
const REQ_MISS = Request(:get, "/nonexistent", "", Headers(), "", Dict{Symbol,Any}())

SUITE["dispatch"]["fixed"] = @benchmarkable Mongoose._dispatchreq($ROUTER, $REQ_ROOT)
SUITE["dispatch"]["dynamic"] = @benchmarkable Mongoose._dispatchreq($ROUTER, $REQ_USERS)
SUITE["dispatch"]["miss"] = @benchmarkable Mongoose._dispatchreq($ROUTER, $REQ_MISS)
