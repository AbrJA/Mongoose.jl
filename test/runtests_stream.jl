# Streaming test runner.
#
# Reports each topic file live (▶ … ✓ / ✗) with flush, so a hang or failure
# pinpoints the exact file as it happens — no waiting for the final summary.
#
# Usage:
#   julia --project=test test/runtests_stream.jl             # fail-fast
#   MONGOOSE_TEST_CONTINUE=1 julia --project=test test/runtests_stream.jl
#   MONGOOSE_TEST_VERBOSE=1 julia --project=test test/runtests_stream.jl
#
# MONGOOSE_TEST_CONTINUE: keep going after a file fails (report and continue).
# MONGOOSE_TEST_VERBOSE: also print each @testset as it starts (helpers.jl).

using Test
using HTTP
import JSON
using Logging

using Mongoose

include("helpers.jl")

const FILES = String[
    "unit/response.jl",
    "unit/request.jl",
    "unit/ws.jl",
    "unit/router.jl",
    "unit/middleware.jl",
    "unit/executor.jl",
    "unit/transport.jl",
    "unit/pipeline.jl",
    "unit/validation.jl",
    "unit/testing.jl",
    "routing/protocol.jl",
    "routing/registration.jl",
    "routing/dsl.jl",
    "routing/dispatch.jl",
    "routing/edge.jl",
    "routing/groups.jl",
    "routing/query.jl",
    "routing/pluggable.jl",
    "routing/compiled.jl",
    "middleware/cors.jl",
    "middleware/ratelimit.jl",
    "middleware/auth.jl",
    "middleware/logger.jl",
    "middleware/health.jl",
    "middleware/metrics.jl",
    "middleware/security.jl",
    "middleware/pipeline.jl",
    "middleware/path.jl",
    "middleware/edge.jl",
    "server/lifecycle.jl",
    "server/edge.jl",
    "server/errors.jl",
    "server/services.jl",
    "server/serverconfig.jl",
    "http/features.jl",
    "http/binary.jl",
    "http/request.jl",
    "http/errors.jl",
    "http/formats.jl",
    "http/streaming.jl",
    "http/static.jl",
    "websocket/websocket.jl",
    "websocket/edge.jl",
    "tls/tls.jl",
]

const CONTINUE = get(ENV, "MONGOOSE_TEST_CONTINUE", "0") == "1"

function run_file(path::String)
    print("▶ ", rpad(path, 26)); flush(stdout)
    t0 = time()
    try
        @testset "$path" begin
            include(path)
        end
        println("✓  ", lpad(string(round(time() - t0; digits=1)), 8), "s")
    catch e
        println("✗  FAILED after ", round(time() - t0; digits=1), "s: ", sprint(showerror, e))
        flush(stdout)
        if CONTINUE
            return false
        end
        rethrow()
    end
    flush(stdout)
    return true
end

@testset "Mongoose.jl (streaming)" begin
    ok = true
    for f in FILES
        ok &= run_file(f)
    end
    ok || error("one or more topic files failed (MONGOOSE_TEST_CONTINUE mode)")
end