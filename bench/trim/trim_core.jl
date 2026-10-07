# Trim probe: juliac --output-exe trim_core --trim=safe --experimental --project=<pkg> bench/trim/trim_core.jl
# Current: 22 verifier errors, all in registration/request paths (Stage 2:
# ParamRoute splats, Function-typed handlers, StreamResponse.producer, FakeStream).
# The `use` builder itself verifies clean.
using Mongoose

@main function main(args)
    app = App()
    app = use(app, cors())
    app = use(app, security())
    app = use(app, etag())
    app = use(app, compress(min_size_bytes=64))
    get!(app, "/hello") do req
        json((message="hello", n=42))
    end
    get!(app, "/users/:id::Int") do req, id
        text("user $id")
    end

    client = FakeTransport(app)
    for (m, p) in ((:get, "/hello"), (:get, "/users/7"), (:get, "/missing"))
        client(m, p; headers=["Accept-Encoding" => "gzip"])
    end
end
