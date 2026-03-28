# Benchmark runner — runs all benchmark suites and generates a report.
#
# Usage:
#   julia --project=benchmark benchmark/run.jl

using BenchmarkTools
using Mongoose
using Dates

const RESULTS = Dict{String, BenchmarkGroup}()

println("=" ^ 60)
println("Mongoose.jl Benchmark Suite")
println("=" ^ 60)
println("Julia: ", VERSION)
println("Date:  ", Dates.format(now(), "yyyy-mm-dd HH:MM"))
println()

# --- Run Router suite ---
println("Running Router benchmarks...")
include(joinpath(@__DIR__, "router.jl"))
RESULTS["Router"] = run(SUITE; verbose=false, seconds=3)
println("  Done.\n")

# --- Run Headers suite ---
println("Running Headers benchmarks...")
include(joinpath(@__DIR__, "headers.jl"))
RESULTS["Headers"] = run(SUITE; verbose=false, seconds=3)
println("  Done.\n")

# --- Print Results ---
println("=" ^ 60)
println("RESULTS")
println("=" ^ 60)

for (suite_name, results) in sort(collect(RESULTS), by=first)
    println("\n## $suite_name\n")
    for (group_name, group) in sort(collect(results), by=first)
        println("### $group_name\n")
        for (bench_name, trial) in sort(collect(group), by=first)
            med = median(trial)
            mn = minimum(trial)
            println("  $bench_name:")
            println("    median: $(BenchmarkTools.prettytime(time(med))), $(BenchmarkTools.prettymemory(memory(med))) allocs: $(allocs(med))")
            println("    min:    $(BenchmarkTools.prettytime(time(mn))), $(BenchmarkTools.prettymemory(memory(mn))) allocs: $(allocs(mn))")
        end
        println()
    end
end

# --- Generate REPORT.md ---
report_path = joinpath(@__DIR__, "REPORT.md")
open(report_path, "w") do io
    println(io, "# Mongoose.jl Benchmark Report\n")
    println(io, "- **Julia**: $(VERSION)")
    println(io, "- **Date**: $(Dates.format(now(), "yyyy-mm-dd HH:MM"))")
    println(io, "- **CPU**: $(Sys.cpu_info()[1].model)")
    println(io, "- **Threads**: $(Threads.nthreads())")
    println(io, "")

    for (suite_name, results) in sort(collect(RESULTS), by=first)
        println(io, "## $suite_name\n")
        for (group_name, group) in sort(collect(results), by=first)
            println(io, "### $group_name\n")
            println(io, "| Benchmark | Median | Min | Allocs | Memory |")
            println(io, "|-----------|--------|-----|--------|--------|")
            for (bench_name, trial) in sort(collect(group), by=first)
                med = median(trial)
                mn = minimum(trial)
                println(io, "| $bench_name | $(BenchmarkTools.prettytime(time(med))) | $(BenchmarkTools.prettytime(time(mn))) | $(allocs(med)) | $(BenchmarkTools.prettymemory(memory(med))) |")
            end
            println(io, "")
        end
    end

    println(io, "---\n*Generated automatically by `benchmark/run.jl`*")
end

println("\nReport written to: $report_path")
