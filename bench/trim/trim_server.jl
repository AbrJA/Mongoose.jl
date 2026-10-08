# Trim probe (real C transport): juliac --output-exe trim_server --trim=safe --experimental --project=<pkg> bench/trim/trim_server.jl
# Status: NOT trim-clean yet — the verifier finds dynamic calls in the transport
# event loop (closures, Tagged reply channel, dispatch_event(::AbstractServer)).
# The StaticRouter/FakeTransport probe (trim_core.jl) is the clean profile.
# Wire test: ./trim_server 8080 10 & then curl http://127.0.0.1:8080/
using Mongoose

function main(args)
    port = isempty(args) ? 8080 : parse(Int, args[1])
    seconds = length(args) >= 2 ? parse(Int, args[2]) : 30

    router = @routes begin
        get("/", req -> json((ok = true,)))
    end
    app = App(router = router)
    app = use(app, cors())

    start!(app; host = "127.0.0.1", port = port, blocking = false)
    sleep(seconds)
    shutdown!(app)
    return 0
end

@main
