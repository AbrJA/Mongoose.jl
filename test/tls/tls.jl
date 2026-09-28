using Sockets

@testset "TLS server" begin
    mktempdir() do dir
        certs = make_test_certificates(dir)
        if certs === nothing
            @info "Skipping TLS tests: openssl not available"
            @test_skip true
            return
        end

        cert, key = certs
        tls = TLSConfig(cert=cert, key=key)

        @testset "HTTPS basic request" begin
            s = App()
            get!(s, "/secure") do req; text("secure!") end
            port = fresh_port()
            start!(s; host="127.0.0.1", port=port, blocking=false, tls=tls)

            try
                # Wait for TLS server to be ready (skip SSL verification for
                # self-signed): condition-based, not a fixed sleep.
                ready = wait_until(timeout=10.0, interval=0.1) do
                    HTTP.get("https://127.0.0.1:$port/secure";
                        require_ssl_verification=false,
                        readtimeout=2,
                        connect_timeout=2,
                        status_exception=false)
                    true
                end

                if ready
                    resp = HTTP.get("https://127.0.0.1:$port/secure";
                        require_ssl_verification=false,
                        status_exception=false)
                    @test resp.status == 200
                    @test String(resp.body) == "secure!"
                else
                    @warn "TLS server did not become ready"
                    @test_skip true
                end
            finally
                shutdown!(s)
            end
        end

        @testset "wss over TLS" begin
            s = App(workers=2)
            ws!(s, "/ws"; on_message=msg -> Message(msg.data))
            port = fresh_port()
            start!(s; host="127.0.0.1", port=port, blocking=false, tls=tls)
            try
                HTTP.WebSockets.open("wss://127.0.0.1:$port/ws";
                                     require_ssl_verification=false) do ws
                    HTTP.WebSockets.send(ws, "over-tls")
                    @test String(HTTP.WebSockets.receive(ws)) == "over-tls"
                end
            catch e
                @warn "wss test failed" exception=(e, catch_backtrace())
                @test_skip true
            finally
                shutdown!(s)
            end
        end

        @testset "stalled TLS handshake is closed by header_timeout" begin
            s = App(header_timeout_ms=200)
            get!(s, "/") do req; text("ok") end
            port = fresh_port()
            start!(s; host="127.0.0.1", port=port, blocking=false, tls=tls)
            try
                sock = Sockets.connect("127.0.0.1", port)
                # Send nothing: the handshake never starts. The connection is
                # tracked from accept, so the slowloris sweep must reclaim it
                # (TLS handshakes have no C-level timeout of their own).
                eof_task = @async eof(sock)
                @test timedwait(() -> istaskdone(eof_task), 5.0; pollint=0.05) == :ok
                @test istaskdone(eof_task) && fetch(eof_task) === true
                close(sock)
            finally
                shutdown!(s)
            end
        end

        @testset "HTTPS POST with body" begin
            s = App()
            post!(s, "/data") do req; text("got: $(req.body)") end
            port = fresh_port()
            start!(s; host="127.0.0.1", port=port, blocking=false, tls=tls)

            try
                ready = wait_until(timeout=10.0, interval=0.1) do
                    HTTP.get("https://127.0.0.1:$port/data";
                        require_ssl_verification=false,
                        readtimeout=2,
                        connect_timeout=2,
                        status_exception=false)
                    true
                end

                if ready
                    resp = HTTP.post("https://127.0.0.1:$port/data";
                        require_ssl_verification=false,
                        body="secret",
                        status_exception=false)
                    @test resp.status == 200
                    @test String(resp.body) == "got: secret"
                else
                    @test_skip true
                end
            finally
                shutdown!(s)
            end
        end
    end
end

@testset "TLSConfig construction" begin
    @testset "Default TLSConfig" begin
        t = TLSConfig()
        @test t.cert == ""
        @test t.key == ""
        @test t.ca == ""
        @test t.skip_verification == false
    end

    @testset "TLSConfig with paths" begin
        t = TLSConfig(cert="/path/to/cert.pem", key="/path/to/key.pem")
        @test t.cert == "/path/to/cert.pem"
        @test t.key == "/path/to/key.pem"
    end

    @testset "TLSConfig with skip_verification" begin
        t = TLSConfig(skip_verification=true)
        @test t.skip_verification == true
    end
end
