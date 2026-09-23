# Quality gates — Aqua + JET over the whole package.
#
# Run with:
#     julia --project=test test/quality/quality.jl

using Test
using Aqua
using JET
using Mongoose
import JSON

println("═══ Aqua ═══")
Aqua.test_all(Mongoose)

println("═══ JET ═══")
# JET's package analysis carries a pinned baseline of known findings. Most are
# false positives from the ergonomic normalizers (untyped `headers=`/`middleware=`
# kwargs) and from `Base` internals; `JSON` is ignored because its parser
# findings are third-party. The gate FAILS when the count grows — lower the
# baseline whenever a finding is fixed.
const JET_BASELINE = 36
result = JET.report_package(Mongoose; ignored_modules=(JSON,), toplevel_logger=nothing)
findings = length(JET.get_reports(result))
println("JET findings: ", findings, " (baseline ", JET_BASELINE, ")")

@testset "JET baseline" begin
    @test findings <= JET_BASELINE
end

println("═══ Quality gates passed ═══")
