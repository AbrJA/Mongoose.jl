"""
    Benchmark runner — runs all benchmark suites and generates a report.

Usage:
    julia --project=benchmark benchmark/run.jl
"""

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

# --- Run each suite ---
for (name, file) in [
    ("Router", "router.jl"),
    ("Headers", "headers.jl"),
]
    println("Running $name benchmarks...")
    mod = Module(Symbol(name, "Bench"))
    suite = Base.eval(mod, quote
        include(joinpath(@__DIR__, $file))
        SUITE
    end)
    results = run(suite; verbose=false, seconds=3)
    RESULTS[name] = results
    println("  Done.\n")
end

# --- Print Results ---
println("=" ^ 60)
println("RESULTS")
println("=" ^ 60)

for (suite_name, results) in sort(collect(RESULTS))
    println("\n## $suite_name\n")
    for (group_name, group) in sort(collect(results))
        println("### $group_name\n")
        for (bench_name, trial) in sort(collect(group))
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

    for (suite_name, results) in sort(collect(RESULTS))
        println(io, "## $suite_name\n")
        for (group_name, group) in sort(collect(results))
            println(io, "### $group_name\n")
            println(io, "| Benchmark | Median | Min | Allocs | Memory |")
            println(io, "|-----------|--------|-----|--------|--------|")
            for (bench_name, trial) in sort(collect(group))
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
