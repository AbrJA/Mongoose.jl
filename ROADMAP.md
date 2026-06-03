# Mongoose.jl — Refactoring Roadmap

## Implementation Order

This roadmap is designed for maximum impact with minimum risk. Each phase builds on the previous and can be validated independently.

---

## Phase 1: Core Simplification (Breaking Changes)

### 1.1 Decompose App into Config + Runtime

**Goal:** Separate what's configured at startup from what's mutated at runtime.

```julia
# Configuration (immutable after construction)
struct AppConfig
    poll_timeout::Int
    max_body::Int
    drain_timeout::Int
    request_timeout::Int
    ws_max_frame::Int
    ws_idle_timeout::Int
    workers::Int
    queuesize::Int
end

# Runtime state (mutable, managed internally)
mutable struct App <: AbstractServer
    const config::AppConfig
    const router::Router
    const middlewares::Vector{AbstractMiddleware}
    const mounts::Vector{Tuple{String,String}}
    const errors::Dict{Int,Union{Response,Function}}
    const services::Dict{Symbol,Any}
    const hooks_start::Vector{Function}
    const hooks_stop::Vector{Function}
    # ... runtime-only fields
end
```

### 1.2 Remove Backward-Compat Aliases

Remove: `plug!`, `event!`, `sse_response`, `:core` property hack.

### 1.3 Simplify Logging

Remove dual-mode AOT/JIT logging. Use Julia's standard `@info`/`@warn`/`@error` with LoggingExtras.jl for formatting.

### 1.4 Fix Type Instabilities

- `params::Vector{Any}` → tuples or typed vectors per route
- `services::Dict{Symbol,Any}` → keep but document the pattern for typed access
- `errors::Dict{Int,Union{Response,Function}}` → acceptable (cold path)

### 1.5 Add JSON Integration

Add JSON3.jl as a dependency (or make it an extension) to enable:
```julia
json(Dict("key" => "value"))  # Works out of the box
json(req)                      # Parses request body
```

---

## Phase 2: Missing Production Features

### 2.1 Multipart Form Data Parsing

```julia
# Goal API:
post!(app, "/upload") do req
    files = multipart(req)
    file = files["avatar"]  # MultipartFile(name, filename, content_type, data)
end
```

### 2.2 Query Parameter Helpers

```julia
# Goal API:
get!(app, "/search") do req
    q = query(req, "q", "")           # String with default
    page = query(req, "page", 1)      # Auto-parse Int
    limit = query(req, "limit", 20)   # Auto-parse Int
end
```

### 2.3 Request Body Validation

```julia
# Goal API using StructTypes or JSON3:
struct CreateUser
    name::String
    email::String
end

post!(app, "/users") do req, body::CreateUser
    # body is validated and parsed from JSON
end
```

### 2.4 GZip Compression Middleware

```julia
use!(app, compress())  # Auto-gzip responses when Accept-Encoding includes gzip
```

### 2.5 TestClient (No Network)

```julia
using Mongoose: TestClient

client = TestClient(app)
resp = client.get("/users")
@test resp.status == 200
```

---

## Phase 3: Router Improvements

### 3.1 Named Routes

```julia
get!(app, "/users/:id::Int", get_user; name=:user_detail)
url_for(app, :user_detail, id=42)  # → "/users/42"
```

### 3.2 Route Metadata for OpenAPI

```julia
get!(app, "/users/:id::Int", get_user;
    summary="Get user by ID",
    tags=["users"],
    responses=Dict(200 => UserResponse, 404 => ErrorResponse)
)
```

---

## Phase 4: Middleware Improvements

### 4.1 Typed Exception Handlers

```julia
struct NotFoundError <: Exception
    resource::String
end

onerror!(app, NotFoundError) do req, err
    json(Dict("error" => "$(err.resource) not found"); status=404)
end
```

### 4.2 Request/Response Hooks

```julia
before_request!(app) do req
    # Runs before routing (e.g., request ID injection)
end

after_response!(app) do req, resp
    # Runs after handler (e.g., add server timing headers)
end
```

---

## Phase 5: WebSocket Improvements

### 5.1 Room-Based Broadcasting

```julia
ws!(app, "/chat/:room") do ws
    on_open(ws) do req
        join_room(ws, req.params["room"])
    end
    on_message(ws) do msg
        broadcast_room(ws, ws.room, msg)
    end
end
```

### 5.2 Typed WebSocket Messages

```julia
ws!(app, "/api/ws") do ws
    on_message(ws) do msg::Dict
        # Auto-parsed JSON
    end
end
```

---

## Phase 6: Documentation & Ecosystem

### 6.1 Update Documentation Structure

```
docs/src/
├── index.md           # Quick start (5 min to first request)
├── tutorial/
│   ├── first_app.md
│   ├── routing.md
│   ├── middleware.md
│   ├── websockets.md
│   ├── testing.md
│   └── deployment.md
├── guides/
│   ├── configuration.md
│   ├── error_handling.md
│   ├── static_files.md
│   ├── streaming.md
│   ├── tls.md
│   └── performance.md
├── api/
│   └── reference.md
└── advanced/
    ├── custom_middleware.md
    ├── extensions.md
    └── internals.md
```

### 6.2 Production Example API

Full CRUD REST API demonstrating:
- All HTTP methods
- JSON request/response
- Path parameters with types
- Query parameters
- Middleware (CORS, auth, rate limit, logging)
- Error handling
- WebSocket real-time updates
- Static file serving
- Health checks
- Metrics endpoint

---

## Implementation Priority (What We'll Do Now)

1. ✅ Simplify `App` struct — remove aliases, clean naming
2. ✅ Add JSON3 as dependency for built-in JSON support
3. ✅ Add multipart form parsing
4. ✅ Add query parameter helpers
5. ✅ Add compression middleware
6. ✅ Add TestClient
7. ✅ Comprehensive test suite (>80% coverage)
8. ✅ Production REST API example
9. ✅ Updated README (FastAPI-quality)
10. ✅ Aqua + JET validation

---

## Files Modified (Expected)

```
src/Mongoose.jl          — Updated exports, add JSON3
src/server/core.jl       — Simplified App struct
src/server/lifecycle.jl  — Remove deprecated aliases
src/protocol/request.jl  — Add query helpers, multipart
src/protocol/response.jl — Simplify, add NamedTuple support
src/middleware/compress.jl — New: GZip middleware
src/testing.jl           — New: TestClient
test/                    — Reorganized, comprehensive coverage
examples/production/     — Full REST API example
README.md               — Complete rewrite
docs/src/               — Updated documentation
Project.toml            — Add JSON3 dependency
```
