"""
    Prometheus-compatible metrics middleware.

    Intercepts every request, records latency and status, and exposes a
    `/metrics` endpoint in Prometheus text exposition format (v0.0.4).

    Metrics exposed:
    - `http_requests_total{method,status}` — counter
    - `http_request_duration_seconds{le}` — histogram (11 finite buckets)
"""

# Standard Prometheus histogram bucket upper bounds (seconds)
const _HIST_BOUNDS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
const _N_HIST_BUCKETS = length(_HIST_BOUNDS) + 1  # +1 for the +Inf bucket

# Number of independent shards 
const _METRICS_SHARDS = 8

const _METRICS_CONTENT_TYPE = "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"

mutable struct _MetricsShard
    lock::Threads.SpinLock
    # Key: "METHOD_STATUSCODE", e.g. "GET_200", "POST_404"
    counts::Dict{String,Int}
    # raw_hist[i] = count of observations that fell in bucket i (non-cumulative).
    # Cumulative sums are computed once at scrape time.
    raw_hist::Vector{Int}
    hist_sum::Float64
    hist_total::Int

    _MetricsShard() = new(
        Threads.SpinLock(),
        Dict{String,Int}(),
        zeros(Int, _N_HIST_BUCKETS),
        0.0, 0
    )
end

struct PrometheusMetrics <: AbstractMiddleware
    shards::Vector{_MetricsShard}
    path::String
end

@inline function _shard(mw::PrometheusMetrics)
    idx = (hash(objectid(current_task())) % _METRICS_SHARDS) + 1
    return mw.shards[idx]
end

# Find the raw (non-cumulative) histogram bucket index for an elapsed time.
@inline function _histidx(elapsed_s::Float64)::Int
    @inbounds for i in 1:length(_HIST_BOUNDS)
        elapsed_s <= _HIST_BOUNDS[i] && return i
    end
    return _N_HIST_BUCKETS
end

function (mw::PrometheusMetrics)(request::AbstractRequest, params::Vector{Any}, next)
    # Serve /metrics directly — skip handler pipeline
    if request.method === :get && request.uri == mw.path
        return _renderstats(mw)
    end

    t0 = time_ns()
    response = next()
    elapsed_s = (time_ns() - t0) * 1e-9

    if response isa Response
        method = uppercase(String(request.method))
        key = string(method, "_", response.status)
        bidx = _histidx(elapsed_s)

        shard = _shard(mw)
        lock(shard.lock)
        try
            shard.counts[key] = get(shard.counts, key, 0) + 1
            @inbounds shard.raw_hist[bidx] += 1
            shard.hist_sum += elapsed_s
            shard.hist_total += 1
        finally
            unlock(shard.lock)
        end
    end

    return response
end

function _renderstats(mw::PrometheusMetrics)::Response
    # --- Aggregate all shards ---
    agg_counts = Dict{String,Int}()
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
        for (k, v) in local_counts
            agg_counts[k] = get(agg_counts, k, 0) + v
        end
        for i in 1:_N_HIST_BUCKETS
            @inbounds agg_raw[i] += local_hist[i]
        end
        agg_sum   += local_sum
        agg_total += local_total
    end

    # --- Build Prometheus text output ---
    io = IOBuffer(sizehint=512)

    # http_requests_total counter
    println(io, "# HELP http_requests_total Total number of HTTP requests")
    println(io, "# TYPE http_requests_total counter")
    for (label, count) in sort!(collect(agg_counts), by=first)
        # label is "METHOD_STATUS" — split at first underscore only;
        # method names are uppercase letters only so the first _ is unambiguous.
        sep = findfirst('_', label)
        if sep !== nothing
            method = label[1:sep-1]
            status = label[sep+1:end]
            println(io, "http_requests_total{method=\"", method, "\",status=\"", status, "\"} ", count)
        end
    end

    # http_request_duration_seconds histogram
    println(io)
    println(io, "# HELP http_request_duration_seconds HTTP request latency in seconds")
    println(io, "# TYPE http_request_duration_seconds histogram")

    # Convert raw (non-cumulative) counts to cumulative for Prometheus format
    cumulative = 0
    for i in 1:length(_HIST_BOUNDS)
        cumulative += @inbounds agg_raw[i]
        println(io, "http_request_duration_seconds_bucket{le=\"", _HIST_BOUNDS[i], "\"} ", cumulative)
    end
    cumulative += @inbounds agg_raw[_N_HIST_BUCKETS]   # +Inf bucket
    println(io, "http_request_duration_seconds_bucket{le=\"+Inf\"} ", cumulative)
    println(io, "http_request_duration_seconds_sum ", agg_sum)
    println(io, "http_request_duration_seconds_count ", agg_total)

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

# Example
```julia
server = Async(router; nworkers=4)
plug!(server, health())
plug!(server, metrics())   # exposes GET /metrics

start!(server, port=8080)
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
    return PrometheusMetrics(shards, path)
end
