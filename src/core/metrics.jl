"""
    Prometheus-compatible metrics middleware.

    Intercepts every request, records latency and status, and exposes a
    `/metrics` endpoint in Prometheus text exposition format (v0.0.4).

    Metrics exposed:
    - `http_requests_total{method,status}` — counter
    - `http_request_duration_seconds{le}` — histogram (11 finite buckets)
"""

const _HIST_BOUNDS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
const _N_HIST_BUCKETS = length(_HIST_BOUNDS) + 1  # +1 for the +Inf bucket

const _METRICS_SHARDS = 8

# Fixed-size counters: (method, status) is a matrix cell, not a string key, so
# the per-request path allocates nothing and the locked section stays tiny.
const _METHOD_NAMES = ("GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD", "OTHER")
const _N_METHODS = length(_METHOD_NAMES)
const _STATUS_MIN = 100
const _STATUS_MAX = 599
const _STATUS_SLOTS = _STATUS_MAX - _STATUS_MIN + 1

@inline function _method_idx(m::Symbol)::Int
    m === :get     && return 1
    m === :post    && return 2
    m === :put     && return 3
    m === :delete  && return 4
    m === :patch   && return 5
    m === :options && return 6
    m === :head    && return 7
    return 8
end

@inline _status_idx(status::Int)::Int = clamp(status, _STATUS_MIN, _STATUS_MAX) - _STATUS_MIN + 1

const _METRICS_CONTENT_TYPE = Pair{String,String}[
    "Content-Type" => "text/plain; version=0.0.4; charset=utf-8"
]

mutable struct _MetricsShard
    lock::Threads.SpinLock
    counts::Matrix{Int}              # (_N_METHODS, _STATUS_SLOTS)
    # raw_hist[i] = count of observations that fell in bucket i (non-cumulative).
    # Cumulative sums are computed once at scrape time.
    raw_hist::Vector{Int}
    hist_sum::Float64
    hist_total::Int

    _MetricsShard() = new(
        Threads.SpinLock(),
        zeros(Int, _N_METHODS, _STATUS_SLOTS),
        zeros(Int, _N_HIST_BUCKETS),
        0.0, 0
    )
end

mutable struct Metrics <: AbstractMiddleware
    shards::Vector{_MetricsShard}
    path::String
    state::Union{Nothing,Function}   # set by `attach!` (server gauges)
end

@doc """
    Metrics — Prometheus-compatible metrics middleware.

    Intercepts every request, records latency and status, and exposes the
    configured `/metrics` endpoint in Prometheus text exposition format.

    Metrics exposed:
    - `http_requests_total{method,status}` — counter
    - `http_request_duration_seconds{le}` — histogram (11 finite buckets)
""" Metrics

@inline function _shard(mw::Metrics)
    return mw.shards[mod1(hash(objectid(current_task())), _METRICS_SHARDS)]
end

"""
    _histidx(elapsed_s) → Int

Return the raw (non-cumulative) histogram bucket index for a given elapsed time in seconds.
"""
@inline function _histidx(elapsed_s::Float64)
    @inbounds for i in 1:length(_HIST_BOUNDS)
        elapsed_s <= _HIST_BOUNDS[i] && return i
    end
    return _N_HIST_BUCKETS
end

function (mw::Metrics)(request::Request, next::Function)
    if request.method === :get && request.uri == mw.path
        return _renderstats(mw)
    end

    t0 = time_ns()
    response = next()
    elapsed_s = (time_ns() - t0) * 1e-9

    # Record both buffered responses and completed streams (SSE). The
    # streaming status is only known at dispatch (200), so streams are
    # bucketed as their nominal status — still visible in the histogram.
    if response isa Response || response isa StreamResponse
        status = response isa Response ? response.status : 200
        mi = _method_idx(request.method)
        si = _status_idx(status)
        bidx = _histidx(elapsed_s)

        shard = _shard(mw)
        lock(shard.lock)
        try
            @inbounds shard.counts[mi, si] += 1
            @inbounds shard.raw_hist[bidx] += 1
            shard.hist_sum += elapsed_s
            shard.hist_total += 1
        finally
            unlock(shard.lock)
        end
    end

    return response
end

function _renderstats(mw::Metrics)
    # --- Aggregate all shards ---
    agg_counts = zeros(Int, _N_METHODS, _STATUS_SLOTS)
    agg_raw    = zeros(Int, _N_HIST_BUCKETS)
    agg_sum    = 0.0
    agg_total  = 0

    for shard in mw.shards
        # Snapshot under lock — only copies, no aggregation.
        local_counts = nothing
        local_hist   = nothing
        local_sum    = 0.0
        local_total  = 0
        lock(shard.lock)
        try
            local_counts = copy(shard.counts)
            local_hist   = copy(shard.raw_hist)
            local_sum    = shard.hist_sum
            local_total  = shard.hist_total
        finally
            unlock(shard.lock)
        end
        # Aggregate outside the lock.
        agg_counts .+= local_counts
        for i in 1:_N_HIST_BUCKETS
            @inbounds agg_raw[i] += local_hist[i]
        end
        agg_sum   += local_sum
        agg_total += local_total
    end

    # --- Build Prometheus text output ---
    io = IOBuffer(sizehint=512)

    println(io, "# HELP http_requests_total Total number of HTTP requests")
    println(io, "# TYPE http_requests_total counter")
    for mi in 1:_N_METHODS
        method = _METHOD_NAMES[mi]
        for si in 1:_STATUS_SLOTS
            count = @inbounds agg_counts[mi, si]
            count == 0 && continue
            println(io, "http_requests_total{method=\"", method,
                "\",status=\"", si + _STATUS_MIN - 1, "\"} ", count)
        end
    end

    # http_request_duration_seconds histogram
    println(io)
    println(io, "# HELP http_request_duration_seconds HTTP request latency in seconds")
    println(io, "# TYPE http_request_duration_seconds histogram")

    cumulative = 0
    for i in 1:length(_HIST_BOUNDS)
        cumulative += @inbounds agg_raw[i]
        println(io, "http_request_duration_seconds_bucket{le=\"", _HIST_BOUNDS[i], "\"} ", cumulative)
    end
    cumulative += @inbounds agg_raw[_N_HIST_BUCKETS]   # +Inf bucket
    println(io, "http_request_duration_seconds_bucket{le=\"+Inf\"} ", cumulative)
    println(io, "http_request_duration_seconds_sum ", agg_sum)
    println(io, "http_request_duration_seconds_count ", agg_total)

    # Server-state gauges (present once `attach!` captured the server).
    if mw.state !== nothing
        st = mw.state()
        for (name, help, value) in (
            ("mongoose_connections", "Currently open connections", st.connections),
            ("mongoose_ws_clients", "Open WebSocket clients", st.ws_clients),
            ("mongoose_active_streams", "In-flight streaming responses", st.streams),
            ("mongoose_executor_inflight", "Jobs currently executing", st.inflight),
            ("mongoose_executor_queue_depth", "Jobs waiting in the executor queue", st.queue_depth),
        )
            println(io, "# HELP ", name, " ", help)
            println(io, "# TYPE ", name, " gauge")
            println(io, name, " ", value)
        end
    end

    return Response(200, _METRICS_CONTENT_TYPE, String(take!(io)))
end

"""
    metrics(; path="/metrics")

Create a Prometheus-compatible metrics middleware.

Exposes an HTTP endpoint (default `/metrics`) in Prometheus text exposition
format v0.0.4. Uses $(_METRICS_SHARDS) internal shards keyed by thread ID to
minimize lock contention under concurrent load.

# Keyword Arguments
- `path::String`: Scrape endpoint path (default: `"/metrics"`).

# Metrics

| Metric | Type | Labels |
|--------|------|--------|
| `http_requests_total` | counter | `method`, `status` |
| `http_request_duration_seconds` | histogram | `le` (11 buckets: 5ms–10s) |
| `mongoose_connections` | gauge | open connections |
| `mongoose_ws_clients` | gauge | open WebSocket clients |
| `mongoose_active_streams` | gauge | in-flight streaming responses |
| `mongoose_executor_inflight` | gauge | jobs currently executing |
| `mongoose_executor_queue_depth` | gauge | jobs waiting in the executor queue |

Gauges are emitted once the middleware is registered (`use!` attaches the
server); before that only the counter and histogram are exposed.

# Example
```julia
app = App(workers=4)
use!(app, health())
use!(app, metrics())   # exposes GET /metrics

start!(app; port=8080)
```

Prometheus `scrape_configs`:
```yaml
- job_name: myapp
  static_configs:
    - targets: ['localhost:8080']
  metrics_path: /metrics
```
"""
function metrics(; path::String="/metrics")
    shards = [_MetricsShard() for _ in 1:_METRICS_SHARDS]
    return Metrics(shards, path, nothing)
end
