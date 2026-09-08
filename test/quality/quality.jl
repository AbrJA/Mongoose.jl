# Quality gates — Aqua + JET over the whole package.
#
# Run with:
#     julia --project=test test/quality/quality.jl

using Aqua
using JET
using Mongoose

println("═══ Aqua ═══")
Aqua.test_all(Mongoose)

println("═══ JET ═══")
JET.report_package(Mongoose)

println("═══ Quality gates passed ═══")