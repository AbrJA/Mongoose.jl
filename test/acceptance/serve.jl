# Playable kitchen-sink server: every Mongoose.jl capability behind one port,
# with an interactive HTML dashboard.
#
#     julia --project=test test/acceptance/serve.jl
#     open http://127.0.0.1:8080/
#
# Exit with Ctrl+C.

using Mongoose
include(joinpath(@__DIR__, "app.jl"))

app = buildapp()
start!(app; port=8080)
println()
println("┌──────────────────────────────────────────────────────┐")
println("│  Mongoose.jl acceptance server                        │")
println("│  Dashboard:  http://127.0.0.1:8080/                   │")
println("│  API token:  test-token                               │")
println("│  Press Ctrl+C to stop.                                │")
println("└──────────────────────────────────────────────────────┘")
println()

try
    sleep(Inf)
catch
    shutdown!(app)
end