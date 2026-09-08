@testset "Response format content types" begin
    s = App()
    get!(s, "/plain") do req; Response(Plain, "text") end
    get!(s, "/html") do req; Response(Html, "<h1>hi</h1>") end
    get!(s, "/json") do req; Response(Json, """{"a":1}""") end
    get!(s, "/css") do req; Response(Css, "body{}") end
    get!(s, "/js") do req; Response(Js, "var x=1") end
    get!(s, "/xml") do req; Response(Xml, "<root/>") end

    with_server(s) do port
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/plain"; status_exception=false), "Content-Type"), "text/plain")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/html"; status_exception=false), "Content-Type"), "text/html")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/json"; status_exception=false), "Content-Type"), "application/json")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/css"; status_exception=false), "Content-Type"), "text/css")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/js"; status_exception=false), "Content-Type"), "javascript")
        @test contains(HTTP.header(HTTP.get("http://127.0.0.1:$port/xml"; status_exception=false), "Content-Type"), "xml")
    end
end

