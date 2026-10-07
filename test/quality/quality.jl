# Quality gates (Aqua + JET): julia --project=test test/quality/quality.jl

using Test
using Aqua
using JET
using Mongoose
import JSON

println("═══ Aqua ═══")
Aqua.test_all(Mongoose)

println("═══ JET ═══")
# Pinned JET baseline (mostly normalizer/Base false positives); the gate fails
# when findings grow — lower it when one is fixed.
const JET_BASELINE = 36
result = JET.report_package(Mongoose; ignored_modules=(JSON,), toplevel_logger=nothing)
findings = length(JET.get_reports(result))
println("JET findings: ", findings, " (baseline ", JET_BASELINE, ")")

@testset "JET baseline" begin
    @test findings <= JET_BASELINE
end

println("═══ Quality gates passed ═══")
