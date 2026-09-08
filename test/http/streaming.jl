@testset "SSE streaming" begin
    @testset "Basic SSE response" begin
        s = App(workers=2)
        get!(s, "/events") do req
            sse(req) do writer
                emit(writer; data="hello", event="greeting")
                emit(writer; data="world", id="1")
            end
        end
        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "data: hello")
            @test contains(body, "event: greeting")
            @test contains(body, "data: world")
            @test contains(body, "id: 1")
        end
    end

    @testset "Slow stream does not block the event loop" begin
        # Worst case: sync mode, single poll thread. A producer that sleeps
        # between events must not stall unrelated HTTP requests.
        s = App()
        get!(s, "/events") do req
            sse(req) do writer
                for i in 1:5
                    emit(writer; data="tick $i")
                    sleep(0.3)
                end
            end
        end
        get!(s, "/fast") do req; text("ok") end

        with_server(s) do port
            # Warm both routes (JIT) so timing measures the loop, not the compiler.
            HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
            HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)

            slow = @async HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
            sleep(0.45)  # the slow stream is mid-production (old code: loop blocked)

            t0 = time()
            resp = HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)
            elapsed = time() - t0

            @test resp.status == 200
            @test String(resp.body) == "ok"
            @test elapsed < 0.5   # streaming path must not stall the loop
            fetch(slow)
        end
    end
end

