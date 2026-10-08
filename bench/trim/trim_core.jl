# Trim probe: juliac --output-exe trim_core --trim=safe --experimental --project=<pkg> bench/trim/trim_core.jl
# Self-checking: exits 0 only when the trimmed binary serves the expected
# responses. Test: ./trim_core; echo $?
# Parity: julia --project=. bench/trim/trim_core.jl; echo $?  (same exit code)
using Mongoose

function main(args)
    router = @routes begin
        get("/hello", req -> json((message = "hello", n = 42)))
        group("/api"; middleware = (cors(origins = "*"),)) do api
            get("/users/:id::Int", (req, id) -> text("user $id"))
        end
    end
    app = App(router = router)
    app = use(app, cors())
    app = use(app, security())
    app = use(app, etag())
    app = use(app, compress(min_size_bytes = 64))

    client = FakeTransport(app)

    r = client(:get, "/hello"; headers = ["Accept-Encoding" => "gzip"])
    (r.status == 200 && occursin("hello", String(r.body))) || return 1

    r = client(:get, "/api/users/7")
    (r.status == 200 && String(r.body) == "user 7") || return 2

    client(:get, "/missing").status == 404 || return 3

    client(:get, "/api/users/abc").status == 404 || return 4

    r = client(:get, "/api/users/7"; headers = ["Origin" => "http://example.com"])
    get(r.headers, "access-control-allow-origin", "") == "*" || return 5

    return 0
end

@main
