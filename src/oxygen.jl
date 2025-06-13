using Oxygen

# Julia version
function fibonacci(n)
    if n <= 1
        return n
    end
    return fibonacci(n - 1) + fibonacci(n - 2)
end

@get "/hello" function()
    fibonacci(35)
    return text("hello world!")
end

serveparallel(port = 8082, access_log = nothing)
