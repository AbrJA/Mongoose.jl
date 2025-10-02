using Mongoose

_fibonacci(n::Int) = n < 2 ? n : _fibonacci(n - 1) + _fibonacci(n - 2)

function fibonacci(request; kwargs...)
    query = request.query
    pattern = r"n=(?<n>\d+)"
    matches = match(pattern, query)
    if matches === nothing
        return MgResponse(request.id, 400, Dict("Content-Type" => "application/json"), "{\"error\":\"Missing 'n' parameter\"}")
    end
    return MgResponse(request.id, 200, Dict("Content-Type" => "application/json"), "{\"value\":$(_fibonacci(parse(Int, matches[:n])))}")
end

mg_register!("GET", "/fibonacci", fibonacci)
mg_serve_threaded!()
# mg_shutdown_threaded!()
