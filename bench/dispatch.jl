# Warm-path performance baselines for Mongoose.jl.
#
#     julia --project=. bench/dispatch.jl                  # print the table
#     BENCH_ASSERT=1 julia --project=. bench/dispatch.jl   # fail on regressions
#
# Measures allocations (B/op) and latency (ns/op) with warm `@allocated` /
# `@elapsed` loops. No BenchmarkTools dependency — runnable with the package
# environment alone. These numbers feed the baselines in
# `.opencode/skills/julia-performance/SKILL.md`.

using Mongoose

const N = parse(Int, get(ENV, "BENCH_N", "200000"))

function measure(f; n::Int=N)
    f()                       # warm up / compile
    a = @allocated for _ in 1:n
        f()
    end
    t = @elapsed for _ in 1:n
        f()
    end
    return (a / n, t / n * 1e9)
end

req = Request(:get, "/", Dict{String,String}(), Pair{String,String}[], "")
reqp = Request(:get, "/users/42", Dict{String,String}(), Pair{String,String}[], "")

frozen = Router(); route!(frozen, :get, "/", r -> text("ok")); freeze!(frozen)
generic = Router(); route!(generic, :get, "/", r -> text("ok"))
fparam = Router(); route!(fparam, :get, "/users/:id::Int", (r, id) -> text("u")); freeze!(fparam)
gparam = Router(); route!(gparam, :get, "/users/:id::Int", (r, id) -> text("u"))

# Contexts are built once: the benchmark measures the request path, not
# context construction (which is a cold, build-phase operation).
ctx_fixed = RequestContext(frozen)
ctx_generic = RequestContext(generic)
ctx_fparam = RequestContext(fparam)
ctx_gparam = RequestContext(gparam)
ctx_mw = RequestContext(frozen; middlewares=(cors(), etag()))
noop(req, next) = next()
scoped = Router(); route!(scoped, :get, "/", r -> text("ok"); middleware=(noop, noop)); freeze!(scoped)
ctx_scoped = RequestContext(scoped)

rows = [
    ("process frozen fixed", () -> process(ctx_fixed, req)),
    ("process generic fixed", () -> process(ctx_generic, req)),
    ("process frozen param", () -> process(ctx_fparam, reqp)),
    ("process generic param", () -> process(ctx_gparam, reqp)),
    ("process frozen + cors+etag", () -> process(ctx_mw, req)),
    ("process frozen + scoped mw", () -> process(ctx_scoped, req)),
    ("mergeheaders", () -> Mongoose.Kernel.mergeheaders(Response(200, "x"), ["A" => "1"])),
    ("asheaders(tuple)", () -> Mongoose.Kernel.asheaders(("a" => "1", "b" => "2"))),
    ("parse_method", () -> Mongoose.parse_method(Mongoose.MgStr(pointer("GET"), 3))),
    ("formatheaders(2)", () -> Mongoose.formatheaders(Headers(["Content-Type" => "text/plain", "X-A" => "1"]))),
    ("Request construct", () -> Request(:get, "/x", Dict{String,String}(), Pair{String,String}[], "")),
    ("parsequery(2 params)", () -> Mongoose.Kernel.parsequery("a=1&b=2")),
]

# Ceilings sit ~30% above the measured baseline: they catch regressions, not
# machine noise. Tighten them whenever a phase lands an improvement.
const LIMITS = Dict(
    "process frozen fixed" => 250.0,
    "process generic fixed" => 420.0,
    "process frozen param" => 700.0,
    "process generic param" => 920.0,
    "process frozen + cors+etag" => 1450.0,
    "process frozen + scoped mw" => 260.0,
    "parse_method" => 50.0,
    "parsequery(2 params)" => 1450.0,  # B2 target: ~0 when unused
)

println(rpad("benchmark", 30), lpad("B/op", 9), lpad("ns/op", 9))
failures = String[]
for (name, f) in rows
    b, ns = measure(f)
    limit = get(LIMITS, name, nothing)
    over = limit !== nothing && b > limit
    over && push!(failures, name)
    println(rpad(name, 30), lpad(round(b; digits=1), 9), lpad(round(ns; digits=0), 9),
        limit === nothing ? "" : (over ? "  OVER ($limit)" : "  ok"))
end

if get(ENV, "BENCH_ASSERT", "0") == "1" && !isempty(failures)
    println("\nFAILED allocation ceilings: ", join(failures, ", "))
    exit(1)
end
