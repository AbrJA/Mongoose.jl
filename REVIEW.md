# Mongoose.jl — Production-Readiness Code Review & Architectural Audit

> Audit date: 2026-10-09 · Julia 1.13.1 · branch `feat/trim-safe` @ `ba8661d`
> Method: full source read of `src/` (9,156 LOC), Aqua+JET quality gates, and
> measured micro-benchmarks (`bench/dispatch.jl` + targeted `@allocated` probes).
> All measurements below were reproduced locally during this audit.

> **Implementation progress (2026-10-10 session):**
> - **H1 landed** (`09f129c`): zero-alloc ASCII case-insensitive matching;
>   `Headers.get`/`header()` 512→0 B, `Bearer` 566→32 B/req,
>   `Connection: close` 640→0 B/req, `PathFilter` 120→0 B/req,
>   pair-`mergeheaders` 176→96 B/op; `process + cors+etag` 1024→768 B/op.
> - **M2 landed** (`f729a2c`): parametric `EndpointCall` + split compiled
>   resolution — generic fixed 224→208 B/op, generic param 672→640,
>   frozen param 544→528 B/op.
> - **B2 landed** (`bbd6d0c`): differential property suite (6,600 checks) found
>   and fixed 4 real dispatch divergences (structural-parsefail 404-vs-400 in
>   frozen/static, catch-all 405-vs-400 priority in static, `hasroute("*")`).
> - **C1 landed**: unknown typed captures throw `RouteError` in both routers.
> - **C2 landed**: `parsemultipart` regex removed; `Response` docstring fixed.
> - **Dispatch parity follow-up**: unknown/mixed-case HTTP methods answer
>   `405`/`404` identically on all three dispatchers (no more `RouteError`→500
>   on generic/static); wire-level test + differential probes added.
> - **M1 withdrawn after measurement**: the compiler already stack-allocates
>   the non-escaping `Next` continuation — 0 extra B/op for 1–4 middleware
>   layers (see §2-M1).
> - Gates after the session: **10,176 tests green**, JET 45 (baseline 47),
>   bench ceilings green, acceptance 79/79, frozen+param 528 B/op.
> - **AOT verified**: `trim_core`, `trim_server`, and the `server.jl` showcase
>   rebuild with **0 verifier errors** (all StaticRouter profiles). The
>   unsupported dynamic-`Router` + `FakeTransport` probe was already
>   non-trimmable before this session (27 verifier errors); `EndpointCall`
>   adds 2 to that JIT-only profile, none to the supported AOT profiles.
> - Remaining: Phase C release prep (acceptance gate in CI), Phase D
>   (1.0 items) — see §5.

---

## 1. Executive Architectural Summary

Mongoose.jl is **in the top tier of Julia web-framework engineering**. It is not
merely "idiomatic": it is one of the most deliberately typed, allocation-budgeted
and AOT-conscious codebases of its class. The architecture is a genuine
implementation of the DESIGN.md vision, not an aspiration:

- **Layered, transport-agnostic core.** `MongooseCore` (nested as `Kernel`) is
  FFI-free: Request/Response/Headers/formats/WS types, the router protocol,
  middleware pipeline and `process` (the request→response seam) run with no C
  library. The server and the Mongoose C adapter sit strictly above it. The
  `FakeTransport` reference transport proves the seam is real, not decorative.
- **Contract-by-fallback protocols.** `AbstractRouter`, `AbstractExecutor`,
  `AbstractTransport` are enforced by throwing fallback methods — a
  partially-implemented custom router fails loudly at the *call site* with a
  `MethodError` naming the missing method. This is the correct Julia idiom for
  traits/interface segregation (no trait-dispatch metaprogramming needed).
- **Value types everywhere, type parameters carrying behavior.** `Endpoint{F,M,MD}`
  captures handler/middleware/metadata types; `Matched{E,P,H}` carries the
  endpoint and the *statically-typed* param tuple; `Request{S}` carries the DI
  registry so `service(req, Val(:x))` is type-stable; `RequestContext{R,M,G}`
  collapses router/middleware/registries into one inferred bundle; `App{R,E,C}`
  is immutable with a mutable `RunState` sidecar (config vs. runtime separation).
- **Zero-per-request-closure pipeline.** `Next <: Function` is an immutable
  continuation built from baked tuples; the frozen router pre-bakes
  terminals (`Terminal`, `ParamCall`, `BoundParams`) so the hot path makes no
  closure/cursor allocations. Measured: **~192 B / 522 ns** per request
  (frozen fixed route), vs ~224 B / 1,722 ns generic.
- **Three dispatch implementations with identical semantics** — generic
  `Router`, the freeze-compiled table (`CompiledDispatch`), and the
  compile-time `StaticRouter`/`@routes`. All three implement 404/405/`Allow`/
  typed-capture-400 identically. `@generated` flat scans replace recursive
  `@inline` scans (compile-memory blowup fix, commit `b70cb6f`).
- **Production hardening that most frameworks skip:** ABI self-check
  (`verify_abi!`), RFC 9112 §6.1 CL+TE smuggling rejection, RFC 7230 §6.3
  `Connection: close` echo, RFC 9110 §15.5.6 `Allow` on 405, slowloris sweeps,
  CRLF-injection guards, constant-time auth comparisons, dotfile static-file
  guards, 503 load-shedding with runaway-task budgets, WS RFC 6455 control-frame
  validation, per-server `@cfunction` with an ARM registry fallback.
- **Quality gates as a first-class workflow:** 3,543 tests, Aqua clean,
  JET at 46 findings *none of which land in Mongoose source frames* (all in
  Base/JSON/StructUtils), allocation ceilings in both `bench/` and
  `test/unit/perf.jl`, a 59-check acceptance suite, and a local AOT (`juliac
  --trim=safe`) verification loop with 0 verifier errors.

The **primary architectural risks** are, in order:

1. **Triple-dispatch divergence.** Three matchers must agree forever. There are
   good differential tests today, but no *property-based* cross-checking (see §5).
2. **Allocating case-insensitive string comparisons on the hot path.** The
   transport lowercases inbound header names, but `Headers.get`/`haskey` call
   `lowercase(k)` on every non-lowercase stored key (which is exactly the case
   for response headers built by middleware and `mergeheaders`). Measured:
   ~256 B **per mixed-case key per lookup**; `conn_close_requested` costs
   640 B/request; `Bearer` 566 B/request. See §3 — this is the single cheapest
   win available (fixes 6 call sites with one utility).
3. **Dynamic handler call in the generic dispatch path.** `matchroute` returns
   `Union{NoMatch,ParamMismatch,MethodMismatch,Matched{E,P,MethodMap}}` where
   `E`/`P` are not resolved, so `invokeendpoint` is a dynamic call
   (1,722 ns vs 522 ns frozen). Acceptable as designed (JIT vs AOT tradeoff),
   but worth documenting explicitly and mitigating for the `TestClient` path.
4. **`Base.get!`/`put!`/`delete!` as route-registration DSL verbs.** Not
   piracy (first argument is owned), but these overload the *semantics* of Base
   container mutation. Fine to keep for the do-block ergonomics; see §2-L3 for
   the 1.0 consideration.
5. **Silent `String` fallback for unknown typed captures.** Both
   `router.jl:325` and `static_router.jl:397` do `get(PARAM_TYPES, tname, String)`
   — `:x::UUID` silently becomes a String capture instead of erroring. A
   footgun that should throw at registration.

Overall verdict: **the core is production-grade today**; the gap to release is
ergonomic polish, the hot-path allocation fixes in §3, and differential-test
hardening of the triple dispatcher.

---

## 2. Key Design Pattern Enhancements

### High Impact

#### H1 — Allocation-free case-insensitive string comparison (one utility, six hot sites)

**Current approach** (`src/core/request.jl:85-109`, `src/core/auth.jl:32`,
`src/transport/mongoose/http_handler.jl:99-105`): every case-insensitive match
allocates via `lowercase`:

```julia
# request.jl — Headers.get: allocates `lowercase(k)` for every stored key
# whose name is not already lowercase (all response headers built by middleware!)
function Base.get(h::Headers, key::String, default)
    lkey = is_lowercase_ascii(key) ? key : lowercase(key)
    @inbounds for i in eachindex(h.data)
        k = h.data[i].first
        if is_lowercase_ascii(k)
            k == lkey && return h.data[i].second
        elseif lowercase(k) == lkey            # ← allocation per mixed-case key
            return h.data[i].second
        end
    end
    return default
end
```

Measured: `get` over 2 lowercase keys = **0 B/op**; over 2 mixed-case keys =
**512 B/op**. `conn_close_requested` (split+strip+lowercase per token) =
**640 B/req** — and it runs on every request that carries `Connection`
(essentially all of them).

**Idiomatic production Julia** — byte-level ASCII comparison, zero allocation:

```julia
# strings.jl — single source of truth for case-insensitive ASCII ops
@inline _lower_byte(b::UInt8) = UInt8('A') <= b <= UInt8('Z') ? b | 0x20 : b

# ci equality of two byte ranges (no String, no lowercase, no alloc)
@inline function _bytes_ci_eq(a::AbstractString, b::AbstractString)::Bool
    na, nb = ncodeunits(a), ncodeunits(b)
    na == nb || return false
    @inbounds for i in 1:na
        _lower_byte(codeunit(a, i)) == _lower_byte(codeunit(b, i)) || return false
    end
    return true
end

# header-name compare against a lowercase literal
@inline function _key_eq(k::String, lkey::String)::Bool
    ncodeunits(k) == ncodeunits(lkey) || return false
    @inbounds for i in eachindex(lkey)
        _lower_byte(codeunit(k, i)) == codeunit(lkey, i) || return false
    end
    return true
end

# token scan with optional OWS — replaces split+strip+lowercase:
@inline function _has_token(value::String, token::String)::Bool
    # walk `value`, compare tokens comma-separated, `_bytes_ci_eq` each
end
```

Then:

```julia
# request.jl — allocation-free get/haskey for ALL stored-key casings
function Base.get(h::Headers, key::String, default)
    lkey = is_lowercase_ascii(key) ? key : lowercase(key)   # key is caller-side; still 1 alloc worst case
    @inbounds for i in eachindex(h.data)
        _key_eq(h.data[i].first, lkey) && return h.data[i].second
    end
    return default
end

# auth.jl
(mw::Bearer)(request, next) = ... startswith_ci(auth_header, "bearer ") ...  # no lowercase(auth_header)

# http_handler.jl
@inline conn_close_requested(req::Request)::Bool = _has_token(get(req.headers, "connection", ""), "close")
```

(For the truly paranoid, `_key_eq`'s loop should use the same
`is_lowercase_ascii` fast path on the stored key first — already-lowercase keys
stay a branch-free byte compare.)

Impact: removes ~640 B/req (`Connection` echo path), ~566 B/req (`Bearer`),
~256 B/mixed-case-key/response (middleware, `mergeheaders`, `_add_header_once`,
`_response_wants_close`, CORS, compress header scans), ~240 B/call (`header()`).

#### H2 — Differential property tests for the three dispatch implementations

**Current approach:** hand-written semantic tests per router
(`test/routing/compiled.jl`, `static_router.jl`, `dispatch.jl`) — good, but they
cover scenarios a human thought of. Three implementations with identical
semantics is an *invariant*, and invariants should be property-tested.

**Idiomatic production Julia** — a tiny generator + cross-check (no new deps;
`Random` suffices):

```julia
# test/routing/differential.jl
const METHODS = (:get, :post, :put, :patch, :delete, :options, :head)
const PATHS = ["/", "/a", "/a/b", "/users", "/users/42", "/users/abraham",
               "/users/42/x", "/files/a/b/c", "/x/:id::Int", "/x/:s", "/x/*rest",
               "/y/:id::Int/z", "*", "/UPPER", "/a//b", "/a%20b", "/a/b?x=1"]

function random_router(rng::AbstractRNG, n::Int)
    r = Router()
    for _ in 1:n
        route!(r, rand(rng, METHODS), rand(rng, PATHS), req -> "x")
    end
    return r
end

@testset "differential: generic == frozen == static" begin
    rng = Xoshiro(0xC0FFEE)
    for trial in 1:200, nroutes in 0:8
        r = random_router(rng, nroutes)
        sr = StaticRouter(Tuple(_static_route_of(r, i) for i in 1:nroutes))  # mirror via matchroute-observable API
        freeze!(r)
        for _ in 1:50
            method, path = rand(rng, METHODS), rand(rng, PATHS)
            a = classify(matchroute(r, method, path))          # frozen (generic impl kept)
            b = classify(matchroute(sr, method, path))         # static
            @test a == b
        end
    end
end
```

`classify` reduces a `RouteResult` to `(kind, statusish, paramstype)` so
`Matched` objects with different endpoint identities still compare semantically.
Extend with: multi-method paths, group prefixes, percent-encodings, wildcard
collisions, same-path-multi-method, and typed-capture parse failures.
This test would have caught the class of bug fixed in `28631fc` at the property
level, not the example level.

### Medium Impact

#### M1 — `Next`: tail-tuple slicing vs. index cursor — **WITHDRAWN (measured)**

**Original concern:** each `next()` call allocates a sliced tuple plus a `Next`
struct via `Base.tail` (`src/core/pipeline.jl:119-132`), so N middleware layers
should cost ~N allocations.

**Measurement (2026-10-10):** Julia's escape analysis already stack-allocates
the continuation when middleware do not stash it:

| middleware layers | B/op |
|---|---|
| 0 | 224 |
| 1 | 256 |
| 2 | 256 |
| 3 | 256 |
| 4 | 256 |
| 2, stashing `next` in a `Ref` | 288 |

One-time +32 B when any middleware runs (the first `Next` construction), then
**flat** — `Base.tail`'s temporaries never reach the heap for the normal
`(req, next) -> next()` shape. An index cursor would replace ~16 B/layer only
in the pathological stashing case, at the cost of a runtime-indexed
heterogeneous `getfield` (which falls off static dispatch). **No action.**

#### M2 — Static endpoint call on the generic path (function barrier on `Matched`)

**Current approach** (`src/core/process.jl:179-199`): the generic path builds a
closure over `(ep, params)` and the handler call inside it is dynamic because
`Matched{E,P}` keeps `E` unresolved in the union:

```julia
ep = result.endpoint            # ::E where E unknown → dynamic call
params = result.params
return ((r) -> invokeendpoint(ep, r, params)), scopedmiddleware(ep)
```

**Idiomatic production Julia** — push the call through a typed barrier so the
endpoint's concrete `F` is reachable before invocation:

```julia
struct EndpointCall{E,P}
    ep::E
    params::P
end
@inline (c::EndpointCall)(r::Request) = invokeendpoint(c.ep, r, c.params)

# in _resolve_terminal:
return EndpointCall(ep, params), scopedmiddleware(ep)
```

The barrier does not remove the `Union` from `matchroute` (that union is
inherent — a router serves many handler types), but it moves the dynamic
dispatch to one well-defined site and, when a given `App` has few routes, lets
inference union-split the small set of endpoint types per context. Net effect
is typically a meaningful share of the 1,722→522 ns gap reclaimed on the
generic path without touching semantics. Low risk; do it after H1 and measure.

#### M3 — Typed-capture registry should throw on unknown types

**Current approach** (`src/core/router.jl:219-223, 325` and
`src/core/static_router.jl:397`): unknown `:x::UUID` silently degrades to a
`String` capture (both paths, identically):

```julia
T = get(PARAM_TYPES, type_str, String)   # silent fallback
```

**Idiomatic production Julia** — fail loudly at registration (a typo'd type is
a programmer error, not a routing policy):

```julia
function _param_type(type_str::String)::Type
    T = get(PARAM_TYPES, type_str, nothing)
    T === nothing && throw(RouteError(
        "unknown route parameter type `$type_str`; supported: $(join(sort!(collect(keys(PARAM_TYPES))), ", ")) " *
        "(extend by adding to the registry or use a String capture)"))
    return T
end
```

Keep the registry itself (or a `paramtype(::Val{:Int})` dispatch table) so
power users can register custom parser types. Update both `router.jl` and the
`@routes` macro path in one commit — they must stay in lockstep (H2 will
enforce this).

### Low Impact

#### L1 — `parsemultipart` compiled-regex and byte-level parsing

`src/core/request.jl:420-424` constructs a `Regex` on every field
(`Regex("$(field)=\"([^\"]*)\"")`) — regex compilation per call. Hoist a
precompiled pattern or hand-roll the quote-scan. Also `_parse_multipart`
materializes a second full copy of the body (`String(copy(data))`) and
`split`s on the boundary — acceptable at current file-size ceilings, but note
the copy when `max_body_bytes` is raised to the 8 MiB ceiling.

#### L2 — `mergeheaders` single-pair fast path

`src/core/response.jl:56-59` routes the single-pair method through the vector
method, allocating a temporary 1-element vector (measured 176 B/op). Direct
path: allocate `n+1` vector + 2 `copyto!`s (~110 B/op). This runs once per
response for every middleware that injects a header (`X-Request-Id` in the
async path, security, cors, etag).

#### L3 — Reconsider `Base.get!`/`put!`/`delete!` as DSL verbs (1.0 decision)

`get!(app, "/path") do req ... end` reads like dict mutation. It is not piracy
(owned types), but it borrows Base *semantics*. If the DSL ever consolidates
behind non-Base names (`route!(app, :get, ...)` + `@get`-style macros), the
do-block sugar survives via the `(f, app, path)` forms. Do not remove now —
just time-box the decision for the 1.0 API freeze with a `@deprecate` path.

#### L4 — Naming cosmetics

`supportsws`/`supportstls`/`supportsstream`, `matchroute`, `hasroute` are
readable-compressed rather than Base-predicate style; `Response`'s docstring
(line 91 of `response.jl`) advertises `headers=[]` while the actual default is
`Headers()`. Fix the docstring; leave the names (documented decision in
AGENTS.md) but add them to a 1.0-naming audit list.

---

## 3. Performance Optimization Blueprint

Measured baselines (this machine, Julia 1.13.1, `bench/dispatch.jl`):

| path | B/op | ns/op | note |
|---|---|---|---|
| process frozen fixed | 192 | 522 | compiled terminal, no middleware |
| process generic fixed | 224 | 1,722 | closure + dynamic `invokeendpoint` |
| process frozen param | 544 | 840 | baked `BoundParams` |
| process generic param | 672 | 2,756 | runtime `_extract` recursion |
| process frozen + cors+etag | 1,024 | 2,216 | 2 middleware layers |
| process frozen + scoped mw | 192 | 636 | tuple pipeline is flat |
| StaticRouter fixed / param | 224 / 672 | — | `@routes` profile |

### Fixes, ordered by (impact × effort)

**1. `Headers.get`/`haskey` mixed-case key allocation** — `src/core/request.jl:85-109`
   - Problem: `lowercase(k)` per non-lowercase stored key. Response headers are
     stored mixed-case by `mergeheaders`/middleware, so *every* response-side
     lookup allocates. Request headers are pre-lowercased by
     `adapter.jl:parse_headers`, so request lookups are already 0 B.
   - Fix: `_key_eq` from §2-H1.
   - Measured: 512 B → 0 B for the 2-mixed-case-key scan.
   - Touches: `Base.get` (85), `Base.haskey` (98), and transitively
     `_add_header_once` (http_handler.jl:73), `_response_wants_close`
     (connection.jl:42), `_echo_conn_close!`, CORS/compress/etag header scans.

**2. `conn_close_requested`** — `src/transport/mongoose/http_handler.jl:99-105`
   - Problem: `split` (Vector{SubString} alloc) + `strip` + `lowercase` per
     token, on **every** request carrying a `Connection` header.
   - Fix: `_has_token` byte-walk (§2-H1).
   - Measured: 640 B/req → ~0 B/req.

**3. `Bearer` auth** — `src/core/auth.jl:32`
   - Problem: `lowercase(auth_header)` + `startswith` per request.
   - Fix: `_starts_ci(auth_header, "bearer ")` byte compare (length check
     first, then 7 bytes).
   - Measured: 566 B/req → ~0 B/req (the remainder is the `Response` build).

**4. `header(req, name)`** — `src/core/request.jl:259`
   - Problem: `lowercase(String(name))` double copy per call.
   - Fix: `get(req.headers, name, nothing)` after making `Headers.get` accept
     `AbstractString` and lowercase once internally only when needed (or keep
     the caller lowercase but avoid the redundant `String` copy).
   - Measured: 512 B → 272 B (→ 0 B once fix 1 lands).

**5. `PathFilter` prefix join** — `src/core/pipeline.jl:54`
   - Problem: `startswith(path, prefix * "/")` allocates the joined string per
     prefix per request.
   - Fix: precompute `prefixes_joined = [p * "/" for p in prefixes]` at
     construction (or store both forms) and compare `path == p || startswith(path, pj)`.
   - Measured: 120 B/req → ~0.

**6. `mergeheaders` single-pair** — `src/core/response.jl:56-59`
   - Fix per §2-L2. Measured: 176 → ~110 B/op.

**7. Generic-path dynamic handler call** — `src/core/process.jl:179-199`
   - Fix per §2-M2 (`EndpointCall` barrier). Re-measure; expect the generic
     rows (1,722/2,756 ns) to move measurably toward the frozen rows.

**8. `Next` tail slicing** — `src/core/pipeline.jl:119-132`
   - Fix per §2-M1 (index cursor). Verify with the trim/AOT probe suite.

**9. `_extract` recursion (generic param path)** — `src/core/router.jl:341-355`
   - This is runtime recursion over `types::Tuple` with dynamic `T = types[1]`
     dispatch per capture. The frozen path already eliminates it; if generic
     param dispatch ever becomes load-bearing (e.g., a non-freezing router use
     case), bake per-segment parse closures exactly as `compiled.jl` does.

**10. Cold-path hygiene (cheap, low priority):**
   - `parsemultipart`/`_extract_field`: hoist regex compilation (§2-L1).
   - `Cors._methods_ok`/`_headers_ok`: precompute allow sets at construction
     (preflight-only; cosmetic).
   - `_any_param_mismatch` (router.jl:401): builds `parts` even when every
     route is fixed — gate on `any(is_wildcard/param)` first, or reuse the
     `_find_route` parts. Only matters on 404 paths.
   - `serve_static!`/`static_file_exists`: `hasroute(server.router, uri)`
     re-splits the path per request when parametric routes exist — cache or
     reuse if static mounts are common in the user base.

### Verified non-issues (do not "optimize")

- `parse_method` — 0 B, 1 ns (byte compares against a const tuple).
- Request-header lookups — already 0 B (adapter lowercases at parse).
- Frozen fixed dispatch — 192 B/op with scoped middleware (flat).
- `stripquery` — SubString, zero-alloc.
- `metricspath` `_record!` — matrix-indexed, lock-only section.
- `AsyncExecutor` queue math (`n_avail`) — correct, no spinning.
- `@setup_workload` — comprehensive; keep in sync with public API changes
  (AGENTS gotcha #12).

---

## 4. Refactored Module Structure

The current layout is already close to optimal. Recommended adjustments are
surgical, not revolutionary:

```
src/
├── Mongoose.jl                  # facade: exports, import block, __init__, precompile
├── core/                        # Kernel — transport-agnostic (UNCHANGED boundary)
│   ├── kernel.jl                # nested module; include order documented
│   ├── base.jl                  # AbstractRequest
│   ├── strings.jl               # + §2-H1: _bytes_ci_eq, _key_eq, _has_token
│   ├── formats.jl               # AbstractFormat, mime, encode/decode
│   ├── status.jl
│   ├── request.jl               # Request, Headers, query — stay together
│   ├── multipart.jl             # NEW: split from request.jl (385-433)
│   ├── cookies.jl               # NEW: Cookie/parsecookies/setcookie (from response.jl)
│   ├── response.jl              # Response, StreamResponse, format_response
│   ├── errors.jl
│   ├── ws_types.jl
│   ├── validation.jl
│   ├── pipeline.jl              # + §2-M1 cursor
│   ├── executor.jl
│   ├── interface.jl             # AbstractRouter protocol + RouteResult ADT
│   ├── transport.jl             # AbstractTransport + capability traits
│   ├── router.jl                # Router, MethodMap, Endpoint
│   ├── groups.jl
│   ├── compiled.jl              # freeze! table
│   ├── process.jl               # RequestContext, errorresponse, pipeline seam
│   ├── static_router.jl         # StaticRouter + @routes
│   ├── streaming.jl             # SSEWriter/emit/sse
│   ├── cors.jl ratelimit.jl auth.jl logger.jl health.jl metrics.jl
│   ├── security.jl compress.jl etag.jl
├── ffi/                         # UNCHANGED: constants, structs, bindings
├── util/log.jl
├── server/                      # UNCHANGED: base, core, registry, lifecycle, sync, async
└── transport/
    ├── mongoose/                # UNCHANGED: adapter, connection, events, ws_handler, http_handler
    └── fake.jl                  # FakeTransport/TestClient (exported; keep in src)
```

Rules this layout preserves (all currently honored, worth re-stating for
contributors):

1. **Kernel must never see `Ptr{Cvoid}`.** The FFI boundary is `adapter.jl`
   (in) and `connection.jl` (out) only.
2. **Include order is a contract.** `strings.jl` before `request.jl`;
   structs used as `App` field types before `server/core.jl`; facade `import`
   block lists every Kernel generic the server/transport layers extend.
3. **One concept, one file.** The two splits proposed above (multipart,
   cookies) break no include-order dependency — verify with the docs build
   after moving (`docs/make.jl`, AGENTS gotcha #11).

Distribution notes for 1.0:

- Consider extracting `Kernel` into a separate `MongooseCore` package **only**
  if a second transport materializes; single-package is right today.
- `Mongoose_jll` is the only hard C dep — keep it behind the facade so a
  future pure-Julia transport can be added without touching `Kernel`.
- If SSE/WebSocket/chunked streams grow a richer API, promote
  `StreamWriter`'s `write`/`flush`/`close` into a documented interface with a
  second implementation in `test/` — the `FakeStreamWriter` already shows the
  shape.

---

## 5. Actionable Roadmap

### Phase A — Hot-path allocation cleanup (2-3 focused commits, measurable)

1. Land `_bytes_ci_eq`/`_key_eq`/`_has_token` in `core/strings.jl`; unit tests
   (ASCII + multibyte-safe behavior, `0 B` `@allocated` guards in
   `test/unit/perf.jl`).
2. Rewire `Headers.get`/`haskey`, `header()`, `conn_close_requested`,
   `Bearer`, `Cors` token checks. Add `Connection`-echo alloc guard.
3. `PathFilter` precomputed joins + `mergeheaders` pair fast path.
4. Tighten `bench/dispatch.jl` ceilings after re-measuring; run
   `examples/aot/build.sh` to confirm the trim build still verifies.

### Phase B — Dispatch-hardening & generic-path speed (2 commits)

5. `EndpointCall` barrier in `_resolve_terminal` (§2-M2); re-measure generic
   rows; keep ceilings in sync.
6. Differential property test suite (§2-H2) — this is the highest-value test
   investment in the repo, given the triple dispatcher.
7. `Next` index cursor (§2-M1) *as a separate commit* with the AOT probes and
   full suite, so it can be reverted independently if the trim verifier
   objects.

### Phase C — API & robustness polish (release-blocking)

8. Unknown typed-capture types throw (`RouteError`) in both routers (§2-M3);
   docs + changelog entry (breaking for silent users, correct behavior).
9. `parsemultipart` regex hoist; `Response` docstring default fix.
10. Changelog `[Unreleased]` → 0.5.0 with the full series summary (already the
    plan per the session log).
11. Wire the acceptance suite into CI as the pre-release gate (currently
    standalone); add the differential suite to the main test set.

### Phase D — 1.0 preparation (after 0.5.0)

12. Resolve the `Base.get!` DSL question (§2-L3) with deprecations if renaming.
13. `T4 LazyRequest` decision (WORKLOG) — revisit only after Phases A-B land;
    current eager-copy design is defensible and the DI/typing story is
    settled. If adopted, the `_construct_from_dict` reflection path in
    `validation.jl` is the first candidate for a generated-function treatment.
14. Transport interface extraction (`T9`) behind `AbstractTransport`, once a
    second real transport exists (the trait seam is sufficient today).
15. Phase 5 features (100-continue, ETag exists, OpenAPI, CSRF, HTTP/2, 1.0)
    per WORKLOG ordering; keep the "small and reliable beats feature count"
    rule from RULES.md §2b.

---

### Summary scorecard

| Dimension | Rating | Basis |
|---|---|---|
| Idiomatic design / multiple dispatch | ★★★★★ | typed ADTs, contract-by-fallback, value-type DI |
| Type stability / inferability | ★★★★☆ | JET-clean own code; generic-path dynamic call is a *chosen* tradeoff |
| Allocation discipline | ★★★★☆ | 192 B/req hot path; §3 items are the last per-request allocs |
| Extensibility | ★★★★★ | three replaceable seams, all exercised by tests and a reference fake |
| API ergonomics | ★★★★☆ | functional-rebuild App; DSL verb discussion pending |
| Robustness / security | ★★★★★ | RFC hardening + ABI check + admission control are best-in-class |
| Testing / QA | ★★★★★ | 3.5k tests, Aqua+JET, bench ceilings, AOT probes, acceptance suite |
| Release readiness | ★★★★☆ | Phase A-C above; no architectural blockers |

**Bottom line:** the architecture is right, the performance budget is
discipline-level, and the remaining work is a short, ordered list of
allocation fixes, differential-test hardening, and API freeze decisions —
not redesign. This is the rare Julia codebase that fully exploits the
language (dispatch, value types, codegen) instead of fighting it.
