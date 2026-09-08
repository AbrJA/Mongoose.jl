@testset "Metrics middleware" begin
    @testset "Exposes /metrics endpoint" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, metrics())

        with_server(s) do port
            for _ in 1:3
                HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            end
            resp = HTTP.get("http://127.0.0.1:$port/metrics"; status_exception=false)
            @test resp.status == 200
            body = String(resp.body)
            @test contains(body, "http_requests_total")
            @test contains(body, "http_request_duration_seconds")
        end
    end

    @testset "Custom metrics path" begin
        s = App()
        get!(s, "/") do req; text("ok") end
        use!(s, metrics(path="/stats"))

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/"; status_exception=false)
            resp = HTTP.get("http://127.0.0.1:$port/stats"; status_exception=false)
            @test resp.status == 200
            @test contains(String(resp.body), "http_requests_total")
        end
    end
end


@testset "Metrics count streaming responses" begin
    app = App()
    get!(app, "/events") do req
        sse(req) do writer
            emit(writer; data="one")
        end
    end
    use!(app, metrics())

    with_server(app) do port
        HTTP.get("http://127.0.0.1:$port/events"; status_exception=false)
        body = String(HTTP.get("http://127.0.0.1:$port/metrics"; status_exception=false).body)
        # The streamed SSE response is counted as a GET_200.
        @test occursin("http_requests_total{method=\"GET\",status=\"200\"} 1", body)
    end
end
