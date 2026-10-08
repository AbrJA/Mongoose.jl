# Trim probe (real C transport): juliac --output-exe trim_server --trim=safe --experimental --project=<pkg> bench/trim/trim_server.jl
# Status: 0 verifier errors; the exe serves requests and static mounts on the C transport.
# Wire test: ./trim_server 8080 & then curl http://127.0.0.1:8080/ and /static/hello.txt ; kill -TERM %1
# AOT profile: the loop runs inline (trimmed exes cannot run tasks), so no
# async workers, streams, or background tasks here.
using Mongoose

function main(args)
    port = isempty(args) ? 8080 : parse(Int, args[1])
    static_dir = length(args) >= 2 ? args[2] : mktempdir()
    router = @routes begin
        get("/", req -> json((ok = true,)))
        ws("/chat", msg -> Message("Echo: " * String(msg.data));
           allowed_origins = ["http://localhost"])
    end
    app = App(router = router)
    app = use(app, cors())

    # Static mounts: concrete (dir, prefix) pairs served by the C helper.
    app = serve!(app, static_dir; uri_prefix = "/static")

    start!(app; host = "127.0.0.1", port = port, blocking = true)
    return 0
end

@main
