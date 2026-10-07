@testset "Binary payloads (bytes, not strings)" begin
    @testset "Binary response preserves all bytes" begin
        payload = UInt8[0x00, 0x01, 0x02, 0xff, 0x00, 0x80, 0x7f]
        s = App()
        get!(s, "/bin") do req
            Response(200, Pair{String,String}["Content-Type" => "application/octet-stream"], payload)
        end

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/bin"; status_exception=false)
            @test resp.status == 200
            bytes = Vector{UInt8}(resp.body)
            @test bytes == payload                # NULs and 0xff survive
            @test length(bytes) == length(payload)
            cl = get(Dict(resp.headers), "Content-Length", "")
            @test cl == string(length(payload))
        end
    end

    @testset "Binary request body round-trip" begin
        payload = UInt8[0x00, 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff]
        s = App()
        post!(s, "/echo-bin") do req
            Response(200, Pair{String,String}["Content-Type" => "application/octet-stream"],
                     codeunits(body(req)))
        end

        with_server(s) do port
            resp = HTTP.post("http://127.0.0.1:$port/echo-bin"; body=payload,
                             status_exception=false)
            @test resp.status == 200
            @test Vector{UInt8}(resp.body) == payload
        end
    end

    @testset "WebSocket binary frame round-trip" begin
        payload = UInt8[0x00, 0x01, 0xfe, 0xff, 0x00]
        s = App()
        ws!(s, "/ws-bin"; on_message=msg -> Message(msg.data))

        with_server(s) do port
            HTTP.WebSockets.open("ws://127.0.0.1:$port/ws-bin") do ws
                HTTP.WebSockets.send(ws, payload)
                data = HTTP.WebSockets.receive(ws)
                got = data isa Vector{UInt8} ? data : Vector{UInt8}(codeunits(String(data)))
                @test got == payload
            end
        end
    end

    @testset "Streaming binary chunks" begin
        chunks = [UInt8[0x00, 0x11], UInt8[0x22, 0x00, 0xff], fill(0x33, 1)]
        s = App()
        get!(s, "/binstream") do req
            StreamResponse(200, "application/octet-stream") do writer
                for c in chunks
                    write(writer, c)
                end
            end
        end

        with_server(s) do port
            resp = HTTP.get("http://127.0.0.1:$port/binstream"; status_exception=false)
            @test resp.status == 200
            @test Vector{UInt8}(resp.body) == reduce(vcat, chunks)
        end
    end
end