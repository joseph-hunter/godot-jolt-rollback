# Phase 6B — Replay profiling and performance plan

[Documentation index](README.md)

Status: initial instrumentation and optimized-build baseline implemented; optimization/budgets pending  
Date: October 15, 2026  
Scope: the existing fixed-topology rollback extension, reusable GDScript manager,
and movement-only forklift labs

## Current implementation

The [initial benchmark results](06b-benchmark-results.md) record controlled local
and localhost network measurements with an isolated optimized extension build.
Opt-in native counters cover restore, capture and complete-step subdivisions.
Fixture-side probes measure inclusive native API calls and participant gameplay,
with correlated, bounded per-correction reports and profiling-on/off comparisons.
The shared production manager's replay algorithm is unchanged.

This is the first diagnostic baseline, not completion of every profiling design
detail below. Manager preflight, input copying, health/status queries and finish
bookkeeping are currently included in an explicit unassigned remainder. The
native API retains one counter set per enabled world; fixtures capture up to 256
correction reports. A general production deferred-report queue and finer manager
subdivisions remain possible follow-up work. No performance optimization or
production budget has been applied.

## 1. Purpose and current evidence

Measure where correction time goes before choosing optimizations or expanding
gameplay scope. Start with timing instrumentation, establish an optimized-build
baseline, then use the results to agree on a replay budget and further work.

The local forklift lab has verified movement replay against reference worlds.
The two-process localhost UDP tests have verified input correction under delay,
jitter, duplication, reordering and burst loss, and explicit failure when the
starting history is unavailable. These results concern the tested Windows build
and movement-only simulation. They do not establish production multiplayer,
combat rollback, cross-platform determinism or acceptable performance.

One recorded network burst case took approximately **114 ms** for its worst
correction in EditorDebug, with a longest replay span of 84 ticks. The fixture
also runs a reference world and instrumentation. This is evidence that profiling
is needed, not an optimized-build baseline or a production performance budget.

Related extension contracts:

- [Physics specification and original phases](00-architecture-and-roadmap.md)
- [Snapshot implementation and restrictions](03-snapshots.md)
- [Replay stepping and callback ownership](04-replay.md)
- [Reusable manager and participant contract](05-manager.md)

The game fixtures are in the sibling `construction-man` repository:
`testinghall/rollback_lab` and `testinghall/rollback_lab/network`. Keep subsequent
game testing scenes, scripts and benchmark helpers under that lab folder.

## 2. Work sequence

These are proposed performance-work milestones within the remaining Phase 6
work. They do not renumber the original implementation phases or declare the
remaining gameplay/network milestones complete.

1. **Instrument:** add opt-in native and script timings with an explicit
   accounting model, bounded collection and machine-readable reports.
2. **Establish a baseline:** benchmark an optimized extension build with the
   existing scenarios, compare profiling enabled/disabled, and separate fixture
   overhead from correction cost.
3. **Agree on budgets:** identify common and worst supported replay spans,
   target machines and frame rates; set correction and memory targets from the
   measurements.
4. **Optimize measured costs:** prioritize the largest verified contributors,
   make one change at a time, and retain all correctness checks.
5. **Proceed to the real-player movement playtest:** after measuring an optimized
   build, agreeing on a practical budget and addressing disruptive replay costs,
   connect the game's input transport to rollback and test with real players on
   separate machines. See [Phase 6C](06c-real-player-playtest.md). Combat remains
   excluded from that initial playtest; detailed transport and session decisions
   will be settled before implementation.

The initial implementation covers instrumentation and baseline collection.
Use the measured results to refine budgets and select the next diagnostic or
optimization work. The sections below retain the broader design and acceptance
criteria; illustrative API/field names are not an interface guarantee.

## 3. Measurement boundary

Preserve the existing `B[t]` boundary and exclusive replay range `[start, end)`.
The manager restores the starting physics and gameplay state once, executes the
historical ticks, captures their corrected results, and returns at `B[end]`.
Final-boundary callbacks remain pending for the normal outer flush. The upcoming
normal tick is outside historical replay and must still execute once.

Measure the manager's **total correction wall time** from entry into its
correction handler through successful completion or failure, including history
preflight and completion/presentation reconciliation performed there. Separately
measure native coordinator/session overhead where practical. Clearly label the
total's actual scope; do not imply it includes the subsequent normal tick, all
of server `sync()`, rendering, packet transit, or time a correction waited in a
queue.

All timing uses a monotonic high-resolution clock and records elapsed durations.
Do not assume native and GDScript absolute clock epochs are interchangeable.
Use integer microseconds in exported data; format milliseconds for humans.
Worker activity is represented by the elapsed time of the synchronous operation,
including required joins. Summed worker CPU time is a different metric and is
outside the first instrumentation milestone.

## 4. First timing breakdown

The manager measures top-level stages. The extension supplies nested detail for
the native calls inside those stages.

| Manager stage | Work included |
|---|---|
| Preflight | Validate replay range, retained inputs and starting gameplay/history availability |
| Physics restore | Complete `rollback_begin_replay()` call |
| Gameplay restore | Copy and restore all participant gameplay snapshots |
| Tick input selection | Select/copy retained corrected inputs and establish tick context |
| Callback delivery | Complete per-world replay callback flush, including gameplay code invoked by callbacks |
| Participant simulation | Shared `rollback_simulate()` dispatch and its synchronous work |
| Boundary capture | Gameplay save/copy plus complete native corrected-snapshot capture/replacement |
| Manual step | Complete per-world native step, including job-system handling |
| Finish | Replay-session completion, interpolation reset and synchronous correction notification |

Native detail should initially distinguish:

| Native operation | Desired nested detail |
|---|---|
| Begin/restore | Ownership/session checks, compatibility validation, Jolt recorder restoration, wrapper restoration and restore-only node synchronization |
| Callback flush | Access/setup and existing query dispatch, preserving normal callback order and eligibility |
| Complete step | Job preparation, wrapper pre-step, Jolt update, wrapper post-step, worker-tail completion/job reclamation |
| Capture/replace | Compatibility/configuration validation, backend recording, wrapper/metadata capture, retained-pool accounting and snapshot replacement/release |
| Session finish | Required end-boundary validation and coordinator bookkeeping |

Adjust the exact internal subdivisions after inspecting the call sites. Mark
unavailable subdivisions as unavailable rather than reporting invented zeroes.
Do not restructure simulation or job ownership merely to make timings easier.
Do not remove compatibility checks or failure safeguards as part of profiling.

### Inclusive and exclusive accounting

Every field must specify its parent and whether its duration is inclusive.
For example, the manager's manual-step duration includes the extension's complete
step. Jolt-update and job-tail durations are children of that native step. They
must not be added to it again when calculating total correction time.

Likewise, force-integration gameplay can execute inside native callback delivery.
Its cost belongs to that callback stage, not also to participant simulation.
Participant simulation can call native raycasts and force APIs; their cost is
included in its wall time unless separately shown as nested detail.

Maintain a non-overlapping top-level stage total and a residual for elapsed time
not attributed to those stages. Do not clamp away or conceal a material accounting
error. Fixed restore/finish costs should be separated from per-tick work; dividing
the complete correction time by its tick count is useful but is not a pure solver
cost or a guarantee of linear scaling.

## 5. Collection and reporting

Profiling should be optional and disabled by default. The normal unprofiled path
should perform no additional clock reads or sample allocations beyond a cheap
enable check. Avoid per-body and per-tick console output, file writes, string
formatting, or unbounded event storage inside the correction boundary.

Accumulate fixed-size counters during a session and retain one structured summary
per correction in a bounded queue/ring. If optional detailed per-tick samples are
later needed, cap them to the replay window and make their extra cost explicit.
Report queue overflow/dropped-profile counts separately from simulation failure.
Reading/exporting a report must not consume callbacks or change stepping state.

Export outside physics coordination, through the fixture/runner. Reports should
correlate native and manager measurements using a session identity scoped to the
world/registration, rather than relying only on timestamps or a correction request
ID that may represent coalesced submissions. Exact public API names and whether
native reports are read by the manager or the harness remain design decisions.

Each correction summary should include:

- Schema version, build/runtime identifiers, profiling mode and fixture/scenario.
- World/session identity, request/coalescing metadata, start/end ticks and
  requested versus successfully completed replay-tick counts.
- Success/failure and failed stage, preserving the original simulation error.
- Total elapsed time, non-overlapping manager stages, nested native stages and
  unaccounted/residual time.
- Relevant work counts: captures, restores, callback flushes, participant
  dispatches and automatic/manual steps; do not assume every body integrates
  every tick.
- Native snapshot count and accounted bytes, with an explicit distinction from
  total process memory and script history storage.

Keep timing summaries numeric and machine-readable. An illustrative human
summary might say: `replayed 24 ticks; total 12.4 ms; restore 0.6 ms; callbacks
0.8 ms; gameplay 2.1 ms; stepping 5.0 ms; capture 3.2 ms; other 0.7 ms`.
These numbers are formatting examples, not measured results or targets.

Failed corrections should retain partial measurements when safe: attempted span,
completed work and the point of failure. Instrumentation must not continue a
failed world, attempt an implicit reset or mask a native diagnostic.

## 6. Optimized-build baseline

Use the isolated game test copy with the actual shared forklift/controller code
and an optimized extension build that retains profiling support. Record the exact
runtime, extension commit, godot-cpp/Jolt pins, compiler, optimization/assertion
settings, determinism configuration, CPU, OS and relevant physics settings. An
optimized extension running under an editor-capable Godot runtime is not the same
configuration as a fully exported release game; label it accurately.

Retain cross-platform determinism configuration and all existing simulation
contracts. Profiled and unprofiled comparisons must use equivalent build flags
apart from the instrumentation mode. Do not compare an assertion-heavy debug
build to an optimized build and attribute the whole difference to profiling.

Initial workload matrix:

- Minimal native/two-body fixtures, to isolate backend costs from forklift logic.
- Forklift drive/collision, flight, full 240-tick replay and ring wrap.
- Controlled short, medium and long correction spans, with exact tick counts
  reported rather than grouping all corrections together.
- Two-process clean, jitter and burst-loss scenarios; stale-history failure as
  a correctness/partial-report case, not a successful replay performance sample.

Warm up before collecting timings and keep warm-up samples separate. Preserve
repeatable commands and starting states for controlled local benchmarks. Network
impairment sequences can be repeatable while arrival ticks still vary with OS
scheduling; report observed replay spans and packet conditions.

For each configuration, record sample count, median, tail percentiles when there
are enough samples, maximum, and total/per-tick duration. Sparse maxima or p99
values must not be presented as stable guarantees. Include profiling-enabled
versus disabled comparisons to estimate measurement overhead.

The correctness harness must continue checking authoritative reference state,
callback eligibility and step counts. Measure its comparison/trace/reporting
cost separately from the correction where possible. If comparisons execute
inside the measured correction, label them as fixture overhead or publish a
separate lean measurement run that uses the same workload and is paired with
the full correctness run. Do not trade correctness evidence for a faster number.

## 7. Acceptance criteria for the first milestone

Instrumentation is ready for baseline collection when:

1. Each completed or failed correction produces a correlated, bounded report
   with clearly defined timing scopes and work counts.
2. Top-level stages reconcile with total elapsed time within stated measurement
   precision; nested measurements do not inflate totals.
3. Existing boundary, snapshot, replay and manager suites, forklift local tests,
   and the network convergence/failure tests still pass under the supported
   configuration, with profiling both enabled and disabled where applicable.
4. No final-boundary callback is consumed early, no extra physics step occurs,
   and live input, failure isolation and snapshot compatibility behavior remain
   unchanged.
5. Collection performs no per-tick console/file I/O, report storage is bounded,
   and disabled/enabled overhead is measured and disclosed.
6. The benchmark records enough build/workload metadata to reproduce its results.

The deliverable is instrumentation and a baseline report identifying the dominant
costs. Optimization and a production budget are subsequent decisions.

## 8. Decisions to settle from the baseline

- Target hardware and rendering frame rates, expected correction frequency and
  typical replay spans, plus the worst supported catch-up case.
- How much frame time corrections may consume alongside ordinary simulation and
  rendering. At 120 Hz a physics interval is about 8.33 ms, but this alone does
  not define the allowed correction budget or the rendering frame budget.
- Which measured costs warrant changes: snapshot validation/storage, copying,
  callback dispatch, forklift raycasts/gameplay, solver work or job handling.
- Whether additional allocation/memory instrumentation is needed after the
  first wall-time breakdown. Native snapshot accounting does not capture script
  allocations, transient peak memory or the complete process footprint.
- A supported failure/recovery policy if history or a future performance limit
  is exceeded. Never silently skip replay ticks, change delta, discard required
  history or spread replay across frames without a separately reviewed ownership
  and simulation contract.

Further discussion should update this plan as decisions are agreed. Subsequent
runtime optimization follows after the measured costs and design are reviewed.
