using Oxygen

@get "/hello" function()
    return text("hello world!")
end

serve(port = 8001, access_log=nothing)
