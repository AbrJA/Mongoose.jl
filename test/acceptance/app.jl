# Kitchen-sink application builder — every Mongoose.jl capability.
#
# Used by:
#   test/acceptance/production.jl  — the acceptance test suite (table-driven
#                                    feature matrix over ONE live server)
#   test/acceptance/serve.jl       — playable HTML-dashboard server
#
# Not wired into `test/runtests.jl` yet: it becomes the last CI gate before
# the next release.

using Mongoose
using Base64

# ── Deterministic test asset: a valid 1x1 transparent PNG ────────────────────
const PNG_1X1 = base64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")

# ── Validation model (typed request validation demo) ─────────────────────────
struct NewUser
    name::String
    age::Int
end

# ── Error types used by the app ──────────────────────────────────────────────
struct ApiNotFound <: Exception
    resource::String
end

# ── The app ──────────────────────────────────────────────────────────────────
function buildapp(; token::String="test-token", workers::Integer=2)
    # Router is fully populated, then frozen: the compiled-dispatch profile.
    router = Router()

    # --- REST CRUD (typed path params) ---
    get!(router, "/api/users") do req
        json(Dict("users" => [Dict("id" => 1, "name" => "Alice"),
                              Dict("id" => 2, "name" => "Bob")]))
    end
    get!(router, "/api/users/:id::Int") do req, id
        1 <= id <= 999 || throw(ApiNotFound("user $id"))
        json(Dict("id" => id, "name" => "User $id"))
    end
    post!(router, "/api/users") do req
        data = json(req)
        json(Dict("created" => data["name"]); status=201)
    end
    delete!(router, "/api/users/:id::Int") do req, id
        text("deleted $id")
    end

    # --- Request features ---
    get!(router, "/api/search") do req
        json(Dict("q" => query(req, "q", ""),
                  "page" => query(req, "page", 1),
                  "limit" => query(req, "limit", 20)))
    end
    post!(router, "/api/form") do req
        form_dict = form(req)
        json(Dict("received" => form_dict))
    end
    post!(router, "/api/upload") do req
        parts = multipart(req)
        file = get(parts, "file", nothing)::Union{MultipartFile,Nothing}
        file === nothing && return json(Dict("error" => "no file"); status=400)
        json(Dict("name" => file.name, "filename" => file.filename,
                  "content_type" => file.content_type,
                  "bytes" => length(file.data),
                  "head" => String(file.data[1:min(8, end)])))
    end
    post!(router, "/api/echo") do req
        body(req)                 # raw return: auto-serialized to text
    end

    # --- Binary responses ---
    get!(router, "/api/binary") do req
        payload = UInt8[0x00, 0x01, 0x02, 0xff, 0x00, 0x80, 0x7f]
        Response(200, ["Content-Type" => "application/octet-stream"], payload)
    end
    get!(router, "/api/png") do req
        Response(200, ["Content-Type" => "image/png"], PNG_1X1)
    end

    # --- Cookies ---
    get!(router, "/api/cookie") do req
        current = get(Mongoose.cookies(req), "session", "none")
        c = Mongoose.Cookie("session", "abc123"; httponly=true, samesite=:lax, max_age=3600)
        text("cookie=$current"; headers=["Set-Cookie" => Mongoose.bake(c)])
    end

    # --- Typed validation ---
    post!(router, "/api/validate") do req
        user = validate(req, NewUser)
        json(Dict("name" => user.name, "age" => user.age))
    end

    # --- GZip target (text/plain, ~1.1KB, clearly compressible) ---
    get!(router, "/api/quote") do req
        text(repeat("All partial functions are structured transformations. ", 20))
    end

    # --- Typed exception handler ---
    get!(router, "/api/boom") do req
        throw(ApiNotFound("everything"))
    end

    # --- Built-in HTTPError (status-carrying exception, automatic mapping) ---
    get!(router, "/api/http-error") do req
        throw(ImATeapotError("short and stout"))
    end

    # --- DI: typed service access ---
    get!(router, "/api/meta") do req
        json(Dict("version" => service(req, Val(:version)),
                  "db" => service(req, Val(:db))))
    end

    # --- SSE ---
    get!(router, "/api/events") do req
        sse(req) do writer
            for i in 1:3
                emit(writer; data="tick $i", event="heartbeat", id=string(i))
            end
        end
    end

    # --- WebSocket echo (text + binary) ---
    ws!(router, "/ws";
        on_message=msg -> Message(msg.data),
        allowed_origins=["http://127.0.0.1", "http://localhost"])

    # --- Compose the app ---
    app = App(; router=freeze!(router), workers=workers,
              services=(version="0.5.0-acceptance", db="memory"))

    # Middleware stack (global).
    use!(app, security())
    use!(app, health())
    use!(app, metrics())
    use!(app, cors(origins="*"))
    use!(app, compress(min_size=64))
    use!(app, logger())
    use!(app, ratelimit(max_requests=100_000, window_seconds=60))
    use!(app, bearer(t -> t == token); paths=["/api"])

    # Custom error pages + typed exceptions.
    onerror!(app, 404) do req
        json(Dict("error" => "Not found", "path" => req.uri); status=404)
    end
    onerror!(app, ApiNotFound) do req, e
        json(Dict("error" => "API: $(e.resource)"); status=404)
    end

    # Static dashboard (HTML/JS) — routes take precedence over static files.
    serve!(app, joinpath(@__DIR__, "dashboard"); uri_prefix="/")

    return app
end