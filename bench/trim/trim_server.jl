# Trim probe (real server; currently blocked by a JuliaC/JLL loading issue).
using Mongoose

@main function main(args)
    app = App(workers=2, middleware=(cors(), security()))
    get!(app, "/") do req
        json((ok=true,))
    end
    start!(app; host="127.0.0.1", port=8080, blocking=false)
    sleep(1)
    shutdown!(app)
end
