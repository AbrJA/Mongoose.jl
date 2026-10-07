# Trim probe: juliac --output-exe trim_core --trim=safe --experimental --project=<pkg> bench/trim/trim_core.jl
# StaticRouter profile: routes are compile-time types, so routing verifies clean.
using Mongoose

@main function main(args)
    router = @router begin
        get("/hello", req -> json((message = "hello", n = 42)))
        get("/users/:id::Int", (req, id) -> text("user $id"))
    end
    app = App(router = router)
    app = use(app, cors())
    app = use(app, security())
    app = use(app, etag())
    app = use(app, compress(min_size_bytes = 64))

    client = FakeTransport(app)
    for (m, p) in ((:get, "/hello"), (:get, "/users/7"), (:get, "/missing"))
        client(m, p; headers = ["Accept-Encoding" => "gzip"])
    end
    return 0
end
