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

function getroot(request; kwargs...)
    return MgResponse(request.id, 200, Dict("Content-Type" => "application/json"), "")
end

mg_register!("GET", "/", getroot)

mg_serve_threaded!(port=3001, async=true)
# mg_shutdown_threaded!()

# mg_serve!()
# mg_shutdown!()
