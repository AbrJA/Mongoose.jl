# Acceptance suite: ONE production-flavored server, every feature, table-driven.
#
#     julia --project=test test/acceptance/production.jl
#
# Not wired into `test/runtests.jl` yet — becoming the last CI gate before the
# next release. It doubles as the executable version of the README/docs demo.

using Test
using HTTP
using Mongoose
import JSON
using CodecZlib

include(joinpath(@__DIR__, "..", "helpers.jl"))
include(joinpath(@__DIR__, "app.jl"))

# One server, many requests: the C server handles keep-alive reuse fine (curl
# proves it), but HTTP.jl's client pooling can wedge a connection after the
# multipart exchange — so the suite uses fresh connections (Connection: close).
const AUTH = ["Authorization" => "Bearer test-token", "Connection" => "close"]
const CLOSE = ["Connection" => "close"]

@testset "Acceptance: kitchen-sink server" begin
    app = buildapp(workers=parse(Int, get(ENV, "ACCEPT_WORKERS", "2")))
    port = fresh_port()
    # blocking=false: the event loop runs on its own task; the test thread
    # drives HTTP requests (with_server does the same).
    start!(app; port=port, blocking=false)
    try
        base = "http://127.0.0.1:$port"
        wait_for_server("$base/healthz"; timeout=10)

        progress(name) = println("▶ ", rpad(name, 34), " …"); flush(stdout)

        progress("REST CRUD + typed params")
        @testset "REST CRUD + typed params" begin
            r = HTTP.get("$base/api/users"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 200
            @test JSON.parse(String(r.body))["users"][2]["name"] == "Bob"

            r = HTTP.get("$base/api/users/42"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 200
            @test JSON.parse(String(r.body))["id"] == 42

            # Typed param mismatch → custom 404 page, not 500.
            r = HTTP.get("$base/api/users/abc"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 404
            @test contains(String(r.body), "Not found")

            r = HTTP.post("$base/api/users"; status_exception=false, headers=AUTH,
                body=JSON.json(Dict("name" => "Carol")))
            @test r.status == 201
            @test JSON.parse(String(r.body))["created"] == "Carol"

            r = HTTP.request("DELETE", "$base/api/users/7"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 200
            @test String(r.body) == "deleted 7"
        end

        progress("Query + form features")
        @testset "Query + form features" begin
            r = HTTP.get("$base/api/search?q=julia&page=2&limit=5"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test JSON.parse(String(r.body)) == Dict("q" => "julia", "page" => 2, "limit" => 5)

            r = HTTP.post("$base/api/form"; status_exception=false,
                headers=["Content-Type" => "application/x-www-form-urlencoded",
                         "Authorization" => "Bearer test-token"],
                body="a=1&b=hello")
            @test r.status == 200
            @test JSON.parse(String(r.body))["received"] == Dict("a" => "1", "b" => "hello")
        end

        progress("Multipart upload (wire)")
        @testset "Multipart upload (wire)" begin
            boundary = "----AcceptanceBoundary"
            raw = "--$boundary\r\n" *
                  "Content-Disposition: form-data; name=\"file\"; filename=\"a.bin\"\r\n" *
                  "Content-Type: application/octet-stream\r\n\r\nfile-body\r\n--$boundary--\r\n"
            r = HTTP.post("$base/api/upload"; status_exception=false,
                headers=["Content-Type" => "multipart/form-data; boundary=$boundary",
                         "Authorization" => "Bearer test-token"],
                body=raw)
            @test r.status == 200
            j = JSON.parse(String(r.body))
            @test j["filename"] == "a.bin"
            @test j["bytes"] == 9
            @test j["head"] == "file-bod"

            r = HTTP.post("$base/api/upload"; status_exception=false, headers=AUTH,
                body="--no-boundary--garbage")
            @test r.status == 400
        end

        progress("Binary + media (wire)")
        @testset "Binary + media (wire)" begin
            r = HTTP.get("$base/api/binary"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 200
            @test r.headers["Content-Type"] == "application/octet-stream"
            @test Vector{UInt8}(r.body) == UInt8[0x00, 0x01, 0x02, 0xff, 0x00, 0x80, 0x7f]
            @test HTTP.header(r, "Content-Length", read_idle_timeout=10) == "7"

            r = HTTP.get("$base/api/png"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 200
            @test r.headers["Content-Type"] == "image/png"
            bytes = Vector{UInt8}(r.body)
            @test bytes == PNG_1X1
            @test bytes[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        end

        progress("GZip compression (wire)")
        @testset "GZip compression (wire)" begin
            encrypted = Dict("version" => "0.5.0-acceptance", "db" => "memory")
            r = HTTP.get("$base/api/meta"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            expected = JSON.json(encrypted)

            gz = HTTP.get("$base/api/meta"; status_exception=false,
                headers=["Accept-Encoding" => "gzip", "Authorization" => "Bearer test-token",
                         "Connection" => "close"])
            @test gz.headers["Content-Encoding"] == "gzip"
            inflated = String(CodecZlib.transcode(CodecZlib.GzipDecompressor, gz.body))
            @test JSON.parse(inflated) == encrypted
        end

        progress("SSE (wire framing)")
        @testset "SSE (wire framing)" begin
            r = HTTP.get("$base/api/events"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 200
            body = String(r.body)
            @test length(findall("event: heartbeat", body)) == 3
            @test contains(body, "data: tick 1")
            @test contains(body, "data: tick 3")
            @test endswith(body, "\n\n")
        end

        progress("WebSocket echo (text + binary)")
        @testset "WebSocket echo (text + binary)" begin
            HTTP.WebSockets.open(HTTP.URI("ws://127.0.0.1:$port/ws", read_idle_timeout=10)) do ws
                HTTP.WebSockets.send(ws, "hello", read_idle_timeout=10)
                @test String(HTTP.WebSockets.receive(ws, read_idle_timeout=10)) == "hello"

                HTTP.WebSockets.send(ws, UInt8[0x00, 0xff, 0x42], read_idle_timeout=10)
                echo = HTTP.WebSockets.receive(ws, read_idle_timeout=10)
                echo_bytes = echo isa Vector{UInt8} ? echo : Vector{UInt8}(codeunits(String(echo)))
                @test echo_bytes == UInt8[0x00, 0xff, 0x42]
            end
        end

        progress("Middleware integration")
        @testset "Middleware integration" begin
            r = HTTP.get("$base/healthz"; status_exception=false, headers=CLOSE, read_idle_timeout=10)
            @test r.status == 200

            r = HTTP.get("$base/metrics"; status_exception=false, headers=CLOSE, read_idle_timeout=10)
            @test r.status == 200
            @test contains(String(r.body), "http_requests_total")

            # Bearer is path-scoped to /api: no token → 401; outside → open.
            r = HTTP.get("$base/api/users"; status_exception=false, read_idle_timeout=10)
            @test r.status == 401
            r = HTTP.get("$base/healthz"; status_exception=false, headers=CLOSE, read_idle_timeout=10)
            @test r.status == 200

            # CORS preflight.
            r = HTTP.options("$base/api/users"; status_exception=false,
                headers=["Origin" => "https://example.com",
                         "Access-Control-Request-Method" => "POST",
                         "Connection" => "close"])
            @test r.status == 204 || r.status == 200
            @test get(Dict(r.headers), "Access-Control-Allow-Origin", "") == "*"

            # Security headers on every response.
            r = HTTP.get("$base/healthz"; status_exception=false, headers=CLOSE, read_idle_timeout=10)
            @test HTTP.hasheader(r, "X-Content-Type-Options", read_idle_timeout=10)
        end

        progress("Error handling")
        @testset "Error handling" begin
            r = HTTP.get("$base/missing"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 404
            @test contains(String(r.body), "\"error\": \"Not found\"")

            r = HTTP.get("$base/api/boom"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 404
            @test contains(String(r.body), "everything")

            # Body limit → 413.
            r = HTTP.post("$base/api/echo"; status_exception=false, headers=AUTH,
                body=repeat("x", 2_000_000))
            @test r.status == 413
        end

        progress("Static dashboard + route precedence")
        @testset "Static dashboard + route precedence" begin
            r = HTTP.get("$base/"; status_exception=false, headers=CLOSE, read_idle_timeout=10)
            @test r.status == 200
            @test contains(String(r.body), "acceptance dashboard")

            # Static files never shadow routes.
            r = HTTP.get("$base/api/users"; status_exception=false, headers=AUTH, read_idle_timeout=10)
            @test r.status == 200
            @test contains(String(r.body), "Alice")
        end

        progress("Frozen router guardrails + request id")
        @testset "Frozen router guardrails + request id" begin
            @test Mongoose.isfrozen(app.router)
            @test_throws Mongoose.RouteError Mongoose.route!(app.router, :get, "/late", req -> text("x"))

            r = HTTP.get("$base/healthz"; status_exception=false, headers=CLOSE, read_idle_timeout=10)
            @test HTTP.hasheader(r, "X-Request-Id", read_idle_timeout=10)
        end
    finally
        shutdown!(app)
    end
end