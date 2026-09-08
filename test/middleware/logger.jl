@testset "Logger middleware" begin
    @testset "Logs to buffer" begin
        io = IOBuffer()
        s = App()
        get!(s, "/logged") do req; text("ok") end
        use!(s, logger(output=io))

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/logged"; status_exception=false)
        end
        output = String(take!(io))
        @test contains(output, "GET")
        @test contains(output, "/logged")
        @test contains(output, "200")
    end

    @testset "Structured JSON logging" begin
        io = IOBuffer()
        s = App()
        get!(s, "/json-log") do req; text("ok") end
        use!(s, logger(output=io, structured=true))

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/json-log"; status_exception=false)
        end
        output = String(take!(io))
        lines = filter(!isempty, split(output, '\n'))
        parsed = JSON.parse(lines[end])
        @test parsed["method"] == "GET"
        @test parsed["status"] == 200
        @test haskey(parsed, "duration")
    end

    @testset "Threshold filtering" begin
        io = IOBuffer()
        s = App()
        get!(s, "/fast") do req; text("ok") end
        use!(s, logger(output=io, threshold=10000))  # 10 seconds — nothing logged

        with_server(s) do port
            HTTP.get("http://127.0.0.1:$port/fast"; status_exception=false)
        end
        @test isempty(take!(io))
    end
end

