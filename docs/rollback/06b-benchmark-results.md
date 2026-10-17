# Phase 6B — Initial optimized-build replay benchmark

[Documentation index](README.md)

Date: October 15, 2026  
Status: baseline recorded; no performance optimization or production budget applied

## Configuration and method

Host: AMD Ryzen 9 5950X 16-Core Processor, 32 logical CPUs, Windows-11-10.0.26200-SP0. Runtime: Godot `4.6.stable.official.89cea1439`. Both extension builds use MSVC 19.38.33143.0, x64/SSE2, single precision and cross-platform determinism enabled. The normal worker-thread configuration is unchanged.

`EditorDevelopment` uses `/O2 /Ob1 /DNDEBUG` with extension `/GL`; Jolt maps to Release. The matched `EditorDebug` build maps Jolt to Debug. Editor tooling/Jolt development profiling remains enabled where specified by the existing build configurations. These run in an editor-capable runtime, not an exported release game.

Optimized samples: 30 measured runs per case/mode after 3 discarded warm-up runs. Debug samples: 5 measured runs per case/mode. Full historical-state checks run separately for every workload/build. Timed local runs retain final/reference agreement, callback and stepping checks but skip expensive historical numerical comparisons. The two interacting forklifts and separate reference world use the real game scene.

Profiling-on/off order alternates across iterations. Times cover shared `_replay()` wall time, including preflight and completion, but exclude diagnostic setup/export, startup, packet waiting and subsequent normal ticks. No per-tick logging occurs. Work counts and non-overlapping timing sums are validated. Percentiles are empirical lower quantiles; local p99 is omitted because each group has fewer than 100 samples.

## Controlled local replay

Primary timings below use total-only mode (two clock reads per correction, detailed native/participant probes off). The debug comparison has fewer repetitions and is a reference, not a stable tail-latency guarantee.

| Workload | Ticks | Debug median (ms) | Optimized median (ms) | Optimized p95 (ms) | Optimized max (ms) | Debug / optimized median |
|---|---:|---:|---:|---:|---:|---:|
| short | 5 | 7.68 | 7.63 | 9.57 | 9.98 | 1.01× |
| medium | 24 | 32.59 | 30.35 | 35.00 | 38.35 | 1.07× |
| long | 120 | 162.90 | 153.06 | 162.71 | 163.97 | 1.06× |
| drive | 140 | 191.29 | 181.47 | 191.39 | 194.42 | 1.05× |
| flight | 160 | 201.31 | 201.38 | 215.81 | 220.31 | 1.00× |
| full_window | 240 | 327.89 | 296.70 | 312.14 | 316.92 | 1.11× |
| wrap | 130 | 177.33 | 163.81 | 172.94 | 174.03 | 1.08× |

## Detailed-mode overhead and attribution

| Workload | Total-only median (ms) | Detailed median (ms) | Median difference |
|---|---:|---:|---:|
| short | 7.63 | 6.68 | -12.5% |
| medium | 30.35 | 30.21 | -0.4% |
| long | 153.06 | 153.92 | +0.6% |
| drive | 181.47 | 180.51 | -0.5% |
| flight | 201.38 | 203.98 | +1.3% |
| full_window | 296.70 | 308.58 | +4.0% |
| wrap | 163.81 | 166.46 | +1.6% |

These differences combine native timers, fixture adapters/dynamic forwarding and scheduling effects. Negative differences do not mean profiling is an optimization. Distributions overlap; this does not establish a universal instrumentation-overhead percentage.

For the 240-tick detailed case, the following are independently calculated median stage values. They need not add exactly to the median total; every individual sample's top-level accounting does reconcile.

| Top-level stage | Median (ms) |
|---|---:|
| fixture_audit | 2.438 |
| gameplay_restore | 0.231 |
| gameplay_save | 15.237 |
| gameplay_simulate | 26.201 |
| native_callbacks | 3.962 |
| native_capture | 14.932 |
| native_finish | 0.002 |
| native_restore | 0.108 |
| native_step | 168.652 |
| manager_other (unassigned remainder) | 77.778 |

Native children below are nested within the native API stages above. **Do not add them again to total time.**

| Native child | Median (ms) |
|---|---:|
| capture_accounting | 0.367 |
| capture_backend | 1.259 |
| capture_compatibility | 4.754 |
| capture_metadata | 7.321 |
| restore_backend | 0.006 |
| restore_nodes | 0.033 |
| restore_validation | 0.050 |
| restore_wrappers | 0.008 |
| step_job_cleanup | 108.406 |
| step_job_prepare | 0.005 |
| step_jolt_update | 58.872 |
| step_wrapper_post | 0.201 |
| step_wrapper_pre | 0.192 |

## Localhost network measurements

Each row combines both peers from the recorded runs. Correction spans vary with scheduling; these are not matched-span local benchmark comparisons. The primary values come from each correction's inner `profiles.corrections.total_usec`, not the legacy outer fixture timer.

| Build / scenario / mode | Corrections | Replay ticks min / median / max | Total median / p95 / max (ms) |
|---|---:|---|---|
| EditorDebug / clean / total | 141 | 4 / 8 / 13 | 11.28 / 15.51 / 17.44 |
| EditorDebug / clean / details | 139 | 4 / 9 / 13 | 12.32 / 16.78 / 18.80 |
| EditorDebug / jitter / total | 97 | 6 / 13 / 24 | 17.36 / 26.64 / 31.86 |
| EditorDebug / jitter / details | 94 | 5 / 14 / 21 | 19.29 / 27.65 / 32.19 |
| EditorDebug / burst / total | 75 | 4 / 15 / 85 | 20.04 / 77.21 / 115.57 |
| EditorDebug / burst / details | 82 | 4 / 14 / 82 | 19.30 / 65.40 / 110.98 |
| EditorDevelopment / clean / total | 431 | 1 / 8 / 20 | 9.59 / 14.26 / 29.45 |
| EditorDevelopment / clean / details | 426 | 3 / 8 / 18 | 9.83 / 15.33 / 21.02 |
| EditorDevelopment / jitter / total | 311 | 6 / 13 / 22 | 14.39 / 23.89 / 29.78 |
| EditorDevelopment / jitter / details | 301 | 5 / 13 / 27 | 14.62 / 26.00 / 37.94 |
| EditorDevelopment / burst / total | 260 | 3 / 13 / 82 | 15.25 / 52.65 / 85.74 |
| EditorDevelopment / burst / details | 263 | 2 / 13 / 86 | 15.78 / 61.30 / 95.73 |

Successful network peer reports summarized above: 48. Each requires complete input recovery, reference agreement for 13 subsequent ticks, peer agreement and exact step counts. Stale-history cases are expected stopped-world failures and are excluded from successful replay latency statistics.

Peak native snapshot accounting was 6,363,428 bytes per rollback world (6.07 MiB). This excludes script histories, profile reports, temporary allocations and total process memory.

## Interpretation and next measurements

The optimized build still stalls on longer corrections. Full-window and burst costs remain visibly large; no production budget has yet been selected. The largest measured native step component is worker completion/reclamation, not the Jolt update alone. Its timer includes the existing post-step wait for worker tails and job reclamation; it does not separate those two operations.

The manager remainder is also substantial. It includes input/state copying, health/status queries, manager bookkeeping and proxy/timing overhead. The current counters do not prove which of these dominates. Snapshot recording alone is not the dominant measured cost.

Recommended next diagnostic experiments: separate worker-tail waiting from reclamation and test controlled worker-count choices while preserving complete job ownership; split manager status/health queries and value validation/copying out of the remainder. Keep the same correctness workloads and paired measurements. Do not remove required joins, snapshot validation, history or callbacks to improve timings.

## Reproduction and limits

Use [the game benchmark guide](../../../construction-man/testinghall/rollback_lab/benchmark/README.md) and the extension helper `scripts/build-replay-benchmark.ps1`. Raw reports and logs are in `construction-man/.godot/replay-benchmarks/EditorDevelopment` and `EditorDebug`; native regression logs are in `godot-jolt-rollback/build/profile-regression`.

Optimized DLL SHA-256: `01080a50451ff6cfeacd665bec8ca6e1524981d4fca4f373fcf5bcbf9fcf87f6`. Commit/diff identifiers and settings are stored in each build's `metadata.json`. Supplementary source hashes are saved beside the benchmark outputs. The game's installed DLL was not replaced. No solver, worker scheduling or gameplay optimization was applied during this baseline.

The optimized DLL passed all 64 existing native scenarios (13 boundary, 14 snapshot, 21 replay, 16 manager). Full-audit local counterparts and all benchmark correctness assertions passed. Headless measurements include fixture/reference work and editor infrastructure; they do not establish rendered frame times, release-export behavior, WAN performance, cross-platform determinism or total process-memory usage.
