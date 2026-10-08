# Trim probe (real C transport): juliac --output-exe trim_server --trim=safe --experimental --project=<pkg> bench/trim/trim_server.jl
# Wire test: ./trim_server 8080 & then curl http://127.0.0.1:8080/ ; kill -TERM %1
# AOT profile: the loop runs inline (trimmed exes cannot run tasks), so no
# async workers, streams, or background tasks here.
using Mongoose

function main(args)
    port = isempty(args) ? 8080 : parse(Int, args[1])
    router = @routes begin
        get("/", req -> json((ok = true,)))
    end
    app = App(router = router)
    app = use(app, cors())
    start!(app; host = "127.0.0.1", port = port, blocking = true)
    return 0
end

@main
