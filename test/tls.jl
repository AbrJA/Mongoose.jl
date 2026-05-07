@testset "HTTPS TLS" begin
    mktempdir() do dir
        creds = make_test_certificates(dir)
        creds === nothing && (@test_skip false; return)
        cert, key = creds

        router = Router()
        route!(router, :get, "/secure", req -> Response(Plain, "tls-ok"))

        s1 = Server(router)
        start!(s1; port=8132, blocking=false, tls=TLSConfig(cert=cert, key=key))
        wait_for_server("https://localhost:8132/"; require_ssl_verification=false)

        try
            resp = HTTP.get("https://localhost:8132/secure"; require_ssl_verification=false)
            @test resp.status == 200
            @test String(resp.body) == "tls-ok"
        finally
            shutdown!(s1)
        end

        s2 = Async(router; nworkers=1)
        start!(s2; port=8133, blocking=false, tls=TLSConfig(cert=cert, key=key))
        wait_for_server("https://localhost:8133/"; require_ssl_verification=false)

        try
            resp = HTTP.get("https://localhost:8133/secure"; require_ssl_verification=false)
            @test resp.status == 200
            @test String(resp.body) == "tls-ok"
        finally
            shutdown!(s2)
        end
    end
end

@testset "TLS Validation" begin
    router = Router()
    route!(router, :get, "/", req -> Response(200, "", "ok"))
    server = Server(router)
    @test_throws ServerError start!(server; port=8134, blocking=false, tls=TLSConfig(cert="only-cert"))
    @test !server.core.running[]
end
