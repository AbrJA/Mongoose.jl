using Mongoose

function greet(req)
    Response(200, "Content-Type: application/json\r\n", "{\"message\":\"Hello World from trimmed Julia!\"}")
end

function echo(req, name)
    Response(200, "Content-Type: text/plain\r\n", "Hello $(String(name))!")
end

@routes MyApp begin
    GET("/hello")       => greet
    GET("/echo/:name")  => echo
end

using Libdl

function my_typed_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})::Cvoid
    ev == Mongoose.MG_EV_POLL && return nothing
    ccall(:puts, Cint, (Cstring,), "my_typed_handler called")
    fn_data = Mongoose.mg_conn_get_fn_data(conn)
    if fn_data == C_NULL
        ccall(:puts, Cint, (Cstring,), "fn_data is NULL!")
        return nothing
    end
    server = Base.unsafe_pointer_to_objref(fn_data)::AsyncServer{Mongoose.Router, MyApp}
    ccall(:puts, Cint, (Cstring,), "server recovered! Calling _invoke_dispatch...")
    Mongoose._invoke_dispatch(server, ev, conn, ev_data)
    return nothing
end

(@main)(ARGS) = begin
    c_handler = @cfunction(my_typed_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    server = AsyncServer(MyApp(); c_handler=c_handler)
    start!(server, port=8099, blocking=true)
    return 0
end
