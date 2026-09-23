---
name: julia-performance
description: Use when writing, reviewing, or optimizing performance-sensitive Julia code in this repository — hot paths, type stability, allocations, benchmarks, JET/@allocated checks, compiled dispatch, middleware, executor, or when asked about performance, allocations, boxing, or "why is this slow".
---

# Julia performance for Mongoose.jl

Ground rules for performance work in this repo. `RULES.md` is the terse policy;
this skill is the working checklist, with the measured baselines to compare
against.

## The ten rules

1. **Type stability is mandatory.** The return type must follow from the
   argument types. Check with `@code_warntype`, `Base.return_types`, and
   `JET.report_opt` before and after a change. A union return is a bug, not a
   style issue.

2. **No abstractly-typed fields in hot structs.** `::Function`, `::IO`,
   `::AbstractMiddleware`, `::AbstractExecutor`, `::Any` fields force a dynamic
   call at every use. Parameterize instead:
   ```julia
   # bad
   struct Bearer; validator::Function; end
   # good
   struct Bearer{F}; validator::F; end
   ```
   Known remaining offenders (accepted or to-fix): `Endpoint.handler`,
   `WSEndpoint` callbacks, `App.context`, `App.executor`.

3. **Function barriers for type-erased containers.** A `Dict`/`Vector` of
   abstract elements erases types; recover specialization by passing the value
   into a function whose argument type is concrete:
   ```julia
   # bad: dynamic call per element
   for f in fs; f(x); end
   # good: barrier specializes on each f
   apply(f::F, x) where {F} = f(x)
   ```
   This is the same trick as `withservices(req) do svcs … end` for DI.

4. **Avoid per-request allocations; measure, don't guess.** Use
   `@allocated`/`@elapsed` loops (warm first) or `BenchmarkTools` in a scratch
   env. Baselines in this repo (Julia 1.13, warm, single thread, per op):

   | Path | B/op | ns/op |
   |---|---|---|
   | `process` frozen fixed route | 384 | ~850 |
   | `process` generic fixed route | 512 | ~1600 |
   | `process` frozen param route | 720 | ~1300 |
   | `process` generic param route | 896 | ~2200 |
   | `process` frozen + `cors()`+`etag()` | 1440 | ~1950 |
   | `mergeheaders` | 368 | ~150 |
   | `asheaders(tuple)` | 112 | ~50 |
   | `parse_method` | 272 | ~200 |
   | `formatheaders` (2 headers) | 336 | ~260 |
   | `Request(...)` (empty) | 224 | ~62 |
   | `parsequery("a=1&b=2")` | 1088 | ~570 |
   | `context(req)` | 304 | ~79 |

   A change that adds a per-request allocation needs a written justification
   in the commit message.

5. **Reuse buffers in hot string paths.** Prefer `IOBuffer(sizehint=…)` +
   one `write`/`String(take!(io))` over chains of `string(...)`. Build log
   lines and hand-framed headers once. `formatheaders` exists for this.

6. **Do not build `Symbol`s or parse strings per request.** `parse_method`
   currently costs ~272 B/op (`lowercase` + `Symbol` intern) — a byte lookup
   table for the seven methods removes it. Same rule for any `Symbol(...)`,
   `lowercase`, or `split` on the request path.

7. **Counters over string-keyed dicts.** `Dict{String,Int}` with a per-request
   key (`"GET_200"`) allocates and locks. Prefer a fixed-size array indexed by
   method/status (`Matrix{Int}` per shard) or `Threads.Atomic` counters.

8. **Keep locks short and sharded.** `SpinLock` is fine only for a few
   instructions; never yield, allocate, or call user code while holding one.
   Prefer atomics for single counters, sharding for maps (see `ratelimit.jl`,
   `metrics.jl`).

9. **`@inbounds` only with a proven bound.** Add it in tight, reviewed loops
   (byte scanning, header formatting, router walking). Never on code that can
   change length underneath you.

10. **Zero non-`const` globals.** All module state must be `const` (a `const
    Ref` or `const` container is fine). This is checked by review, not the
    compiler.

## Hot-path map

| Layer | Files | Notes |
|---|---|---|
| Event dispatch | `transport/mongoose/events.jl`, `http_handler.jl` | poll thread; no user code here beyond dispatch |
| Request adaptation | `transport/mongoose/adapter.jl` | `parse_method`, `parse_headers`, `remote_addr_of` allocate per request |
| Routing | `core/router.jl`, `core/compiled.jl` | generic param match allocates `Vector{String}`; **`freeze!` + compiled dispatch is the fast path** |
| Pipeline | `core/pipeline.jl`, `core/process.jl` | one closure + cursor per request; tuple stacks are cheaper than vectors |
| Middleware | `core/*.jl` | each header-adding middleware calls `mergeheaders` (368 B) |
| Executor | `core/executor.jl`, `server/async.jl` | `Channel{Function}` boxes jobs; `Threads.@spawn` per timed request |
| Streaming | `transport/mongoose/connection.jl` | producers write to a bounded channel; loop drains |

## Preferred patterns

```julia
# Specialize on callables instead of annotating ::Function
submit!(exec, job::F) where {F} = job()          # not job::Function

# Parametric structs for anything stored and called
struct Endpoint{F}; handler::F; middleware::Vector{AbstractMiddleware}; end

# Fixed-size counters, no per-request keys
counts[method_idx(m), min(status, 599) + 1] += 1

# One buffer per formatted payload
io = IOBuffer(sizehint=128); print(io, …); write(sock, take!(io))

# Function barrier to recover specialization from a container
foreach(mws) do mw; invoke_mw(mw, req); end   # invoke_mw specializes on typeof(mw)
```

## Verification workflow

```sh
# gates (must stay green)
julia --project=test test/runtests.jl
julia --project=test test/quality/quality.jl      # Aqua + JET baseline

# allocation spot-check (warm first, then measure a loop)
julia --project=. -e '
  using Mongoose; f() = process(RequestContext(Router()), Request(:get,"/",Dict{String,String}(),Pair{String,String}[],""))
  f(); println(@allocated f())'

# optimization report for a specific call signature
julia --project=test -e 'using JET, Mongoose; JET.report_opt(f, (T1, T2))'
```

When touching `core/compiled.jl`, `core/pipeline.jl`, `core/router.jl`, or
`transport/mongoose/connection.jl`, re-run the allocation table above and put
before/after numbers in the commit message.

## AOT/trim constraint (batch 10 in WORKLOG)

Trimming removes code proven unreachable, so **runtime `apply_type` from
erased values is fatal**: `Terminal{typeof(handler)}` built from
`Endpoint.handler::Function`, `ParamRoute{P}` built from a runtime tuple, and
dynamic dispatch through abstract fields all fail `juliac --trim=safe` (62
verifier errors today; `--trim=unsafe` builds but crashes). Any performance
redesign of routing/execution should move the route table into a type
parameter (`@routes`/`StaticRouter{Routes<:Tuple}`) and keep `App` parametric
in its executor/middleware types — the same changes that fix trim also remove
per-request dynamic dispatch.

## Anti-patterns seen here (don't repeat)

- `@nospecialize(handler::Function)` at registration: keeps compile time down
  but guarantees a dynamic call in the generic path. Acceptable only because
  the compiled path re-captures types — don't add more.
- Eager `Dict{Symbol,Any}` per request for DI (`context(req)`), even when the
  handler never reads it. Prefer typed DI via handler wrapping at registration.
- Recomputing per-connection values per request (`remote_addr`, request id)
  when they could be cached on the connection record.
- Copying headers into a fresh `Headers` for every middleware
  (`mergeheaders`) to keep shared `const Response`s safe. The copy is
  deliberate; document any in-place mutation instead of adding more copies.
- Internal APIs in hot paths (`Base.n_avail`) — pin with a test so an upgrade
  fails loudly rather than silently misbehaving.
