using Oxygen

@get "/hello" function()
    return json(Dict(:message => "hello world!"))
end

serve()
