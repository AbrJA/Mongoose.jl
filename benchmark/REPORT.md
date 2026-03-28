# Mongoose.jl Benchmark Report

- **Julia**: 1.12.5
- **Date**: 2026-03-27 23:22
- **CPU**: Intel(R) Core(TM) i7-9800X CPU @ 3.80GHz
- **Threads**: 1

## Headers

### construct

| Benchmark | Median | Min | Allocs | Memory |
|-----------|--------|-----|--------|--------|
| 10_pairs | 81.000 ns | 78.000 ns | 2 | 224 bytes |
| 5_pairs | 28.000 ns | 24.000 ns | 2 | 144 bytes |
| empty | 21.000 ns | 18.000 ns | 1 | 32 bytes |

### format

| Benchmark | Median | Min | Allocs | Memory |
|-----------|--------|-----|--------|--------|
| 10_headers | 579.000 ns | 528.000 ns | 8 | 1008 bytes |
| 5_headers | 327.000 ns | 302.000 ns | 6 | 400 bytes |
| empty | 20.000 ns | 17.000 ns | 0 | 0 bytes |

### lookup

| Benchmark | Median | Min | Allocs | Memory |
|-----------|--------|-----|--------|--------|
| 10_hit_first | 285.000 ns | 268.000 ns | 14 | 512 bytes |
| 10_hit_last | 2.677 μs | 2.440 μs | 140 | 4.97 KiB |
| 10_miss | 2.510 μs | 2.278 μs | 140 | 4.97 KiB |
| 5_hit_first | 304.000 ns | 268.000 ns | 14 | 512 bytes |
| 5_hit_last | 1.158 μs | 1.069 μs | 70 | 2.39 KiB |
| 5_miss | 1.229 μs | 1.139 μs | 70 | 2.47 KiB |

### response

| Benchmark | Median | Min | Allocs | Memory |
|-----------|--------|-----|--------|--------|
| headers_formatted | 322.000 ns | 301.000 ns | 6 | 400 bytes |
| raw_string | 55.000 ns | 51.000 ns | 0 | 0 bytes |
| typed_no_headers | 38.000 ns | 34.000 ns | 1 | 64 bytes |
| typed_with_headers | 351.000 ns | 326.000 ns | 7 | 608 bytes |

## Router

### dispatch

| Benchmark | Median | Min | Allocs | Memory |
|-----------|--------|-----|--------|--------|
| dynamic | 1.116 μs | 1.026 μs | 15 | 640 bytes |
| fixed | 106.000 ns | 98.000 ns | 4 | 160 bytes |
| miss | 125.000 ns | 110.000 ns | 3 | 112 bytes |

### match

| Benchmark | Median | Min | Allocs | Memory |
|-----------|--------|-----|--------|--------|
| dynamic_1param | 997.000 ns | 975.000 ns | 12 | 512 bytes |
| dynamic_deep | 1.604 μs | 1.115 μs | 13 | 560 bytes |
| fixed_about | 58.000 ns | 51.000 ns | 1 | 32 bytes |
| fixed_deep | 61.000 ns | 54.000 ns | 1 | 32 bytes |
| fixed_root | 62.000 ns | 51.000 ns | 1 | 32 bytes |
| miss_deep | 214.000 ns | 188.000 ns | 4 | 176 bytes |
| miss_shallow | 110.000 ns | 102.000 ns | 2 | 80 bytes |

### register

| Benchmark | Median | Min | Allocs | Memory |
|-----------|--------|-----|--------|--------|
| dynamic_5 | 1.482 μs | 1.344 μs | 43 | 1.94 KiB |
| static_5 | 422.000 ns | 375.000 ns | 14 | 1.02 KiB |

---
*Generated automatically by `benchmark/run.jl`*
