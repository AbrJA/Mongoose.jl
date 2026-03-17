using Mongoose
using HTTP

server = AsyncServer(nworkers=4)

ws!(server, "/chat", on_message = function(msg::WsMessage)
    if msg.is_text
        println("Server received text: ", msg.data)
        return "Echo: " * msg.data
    else
        println("Server received binary of length: ", length(msg.data))
        return msg.data
    end
end, on_open = function(req::HttpRequest)
    println("Server opened WS connection! Headers: ", req.headers)
end, on_close = function()
    println("Server closed WS connection!")
end)

start!(server, port=8097, blocking=false)
sleep(0.5)

HTTP.WebSockets.open("ws://localhost:8097/chat") do ws
    HTTP.WebSockets.send(ws, "Hello WebSockets!")
    response = HTTP.WebSockets.receive(ws)
    println("Client received: ", String(response))
    
    # Send binary
    HTTP.WebSockets.send(ws, UInt8[1, 2, 3])
    response = HTTP.WebSockets.receive(ws)
    println("Client received binary: ", response)
end

shutdown!(server)
