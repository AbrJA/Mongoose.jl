# A middleware is a function that takes (request, params, next_func)
# and returns a Response or calls next_func()

function use!(server::Server, middleware::Middleware)
    push!(server.core.middlewares, middleware)
    return server
end
