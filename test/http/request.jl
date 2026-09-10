@testset "Request features" begin
    @testset "Headers are case-insensitive" begin
        s = App()
        get!(s, "/headers") do req
            val = header(req, "x-custom-header")
            text(isnothing(val) ? "missing" : val)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/headers";
                status_exception=false,
                headers=["X-Custom-Header" => "hello"])
            @test String(resp.body) == "hello"
        end
    end

    @testset "Context per request" begin
        s = App()
        get!(s, "/ctx") do req
            c = context(req)
            c[:user_id] = 42
            uid = c[:user_id]
            text("uid=$uid")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/ctx"; status_exception=false)
            @test String(resp.body) == "uid=42"
        end
    end

    @testset "Query parameters parsed" begin
        s = App()
        get!(s, "/q") do req
            a = get(req.query, "a", "")
            b = get(req.query, "b", "")
            text("$a,$b")
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/q?a=1&b=hello"; status_exception=false)
            @test String(resp.body) == "1,hello"
        end
    end

    @testset "Remote address from the C connection" begin
        s = App()
        get!(s, "/remote") do req
            addr = req.remote_addr
            text(isnothing(addr) ? "none" : addr)
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/remote"; status_exception=false)
            # Loopback client: the peer IP is the machine's own loopback.
            @test occursin("127.0.0.1", String(resp.body))
        end
    end
end

