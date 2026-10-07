# Quality gates (Aqua + JET): julia --project=test test/quality/quality.jl

using Test
using Aqua
using JET
using Mongoose
import JSON

println("═══ Aqua ═══")
Aqua.test_all(Mongoose)

println("═══ JET ═══")
# JET findings are Julia-version-dependent and the baseline is pinned to the
# latest release; LTS legs run Aqua only (JET there is slow and off-baseline).
if VERSION >= v"1.11"
    const JET_BASELINE = 47
    result = JET.report_package(Mongoose; ignored_modules=(JSON,), toplevel_logger=nothing)
    findings = length(JET.get_reports(result))
    println("JET findings: ", findings, " (baseline ", JET_BASELINE, ")")

    @testset "JET baseline" begin
        @test findings <= JET_BASELINE
    end
else
    println("JET findings: skipped on Julia ", VERSION, " (baseline is version-pinned)")
end

println("═══ Quality gates passed ═══")
