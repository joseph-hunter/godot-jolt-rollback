# Phase 4 — Historical replay inside sync

[Documentation index](README.md)

Implemented October 13, 2026. This extends the
[snapshot implementation](03-snapshots.md) with controlled
per-world replay inside a synchronous correction callback. All 21 replay scenarios,
14 snapshot scenarios and 13 boundary scenarios passed on the pinned Godot 4.6
Windows x64 runtime. Ten consecutive incomplete-replay/shutdown stress runs passed.

## Correction lifecycle

The manager submits correction notification outside physics callback dispatch.
At the next active `sync()`, the extension invokes the selected manager with
`kind="correction_pending"` and `replay_available=true`. The manager restores
physics through `rollback_begin_replay()`, restores its own gameplay state,
selects retained corrected inputs, and repeats this sequence for `[start, end)`:

```gdscript
if not physics.rollback_begin_replay(space, starting_handle, start, end):
    return false
restore_gameplay_snapshot(start)
for tick in range(start, end):
    select_retained_corrected_input(tick)
    if not physics.rollback_flush_replay_callbacks(space, tick):
        return false
    simulate_participants(tick, 1.0 / 120.0)
    if not physics.rollback_step_manual(space, tick, 1.0 / 120.0):
        return false
    save_gameplay_snapshot(tick + 1)
    if physics.rollback_capture_physics(space, tick + 1) == 0:
        return false
return physics.rollback_finish_replay(space, end)
```

The sample functions are manager responsibilities, not additional extension APIs.
Missing input/gameplay history must explicitly fail the world and return false.
The starting boundary is restored once. Capture replaces every corrected result
boundary and its handle; the abandoned timeline's corresponding handles expire.

After successful correction, the same sync invokes the manager again with
`kind="normal_boundary"`. That notification selects the upcoming live input.
The outer loop then flushes the final boundary's pending callbacks, runs normal
participant gameplay, and advances the world once. Historical ticks never
re-enter SceneTree physics processing or server `sync()`.

## APIs and enforced ordering

| Method | Contract |
|---|---|
| `rollback_begin_replay(space, handle, start, end) -> bool` | Only inside the selected pending-correction callback; restore `B[start]` and open one session, at most 240 ticks, ending at the world's current logical boundary. |
| `rollback_flush_replay_callbacks(space, tick) -> bool` | Deliver the existing per-world callback path once for the current historical tick. Require a captured pre-callback boundary; reject `tick >= end`. |
| `rollback_step_manual(space, tick, delta) -> bool` | Only after that tick's callback delivery; execute complete pre/update/post work plus job handling at fixed `1/120`. Advance historical tick once. |
| `rollback_capture_physics(space, tick) -> int` | During replay, only the current pre-callback boundary may be captured. The next flush and session finish require the corresponding corrected capture. |
| `rollback_finish_replay(space, tick) -> bool` | Require the exclusive end, a corrected final snapshot, and final callbacks still undelivered. Close the session successfully. |

Ordinary and replay steps share `_step_space()`. It performs job-system pre-step,
the full `JoltSpace3D::step()` (wrapper pre-step, Jolt update, wrapper post-step),
and job-system post-step. Jolt errors use the Phase 3 failure path. Replay flush
uses `JoltSpace3D::call_queries()` and its original rigid-body/area order and
eligibility machinery, although unsupported areas/contact callbacks remain
excluded by the snapshot contract. `has_stepped` and `sync_state` remain restored
metadata, so initial and sleeping boundaries keep their eligibility rules.

Capture after callback delivery, repeat flush/step, omitted intermediate/final
captures, releasing the current replay boundary, nested restoration/session creation, manual stepping outside a session,
wrong delta/end, and early callback return all stop the world. Topology free
operations during a session are rejected. Reentrant restore/step requests from
integration are rejected while flushing. A partially failed correction suppresses
the subsequent automatic step and registered participant script updates; it does
not attempt to continue from uncertain physics state.

The manager owns logical numbering. Capture/restoration bind a logical boundary
to the current automatic-step counter. The callback context's `tick` and status
`logical_tick` report that binding advanced by later automatic ticks; it is `-1`
before the first binding. This lets replay validate its requested ending boundary
without using engine frame counters. `completed_steps` counts automatic steps
since registration; `replay_steps` counts successful historical steps separately.
Status also exposes `replay_active`, `replay_tick` and `replay_end`. A test with
logical tick origin 1000 verifies the separation from automatic step numbering.

## Worker completion and retained-history validation

Jolt's solver barrier guarantees completed simulation state. A worker callback
can still be completing profiling and dropping its queue reference afterward.
The old post-step drain could miss that late `FreeJob`; replay failure/shutdown
stress testing exposed a fixed-free-list assertion during destruction.

The job system now counts queued worker callbacks, waits until their profiling
and reference-release tails finish, and then drains completed jobs. Each job's
destructor still joins its native WorkerThreadPool task. The job-system destructor
also drains before destroying the pool. This makes repeated complete steps and
failure shutdown safe without an asynchronous correction protocol.

Each admitted snapshot is compatible with every retained snapshot by invariant.
New capture now validates against one retained immutable signature, then accounts
for the full pool's memory, avoiding repeated comparison of 241 equivalent
configuration dictionaries on every historical tick. Compatibility checks and
the 64 MiB accounting limit remain enforced; incompatible-capture/restore tests
still pass.

## Reference comparison and evidence

`replay-test.tscn` runs two interacting rigid bodies in the registered predicted
world and two bodies in an ordinary reference world. The reference uses corrected
inputs from the beginning. The predicted world initially uses wrong inputs and
must demonstrably diverge before correction. The manager keeps 240 tagged input
slots and 241 tagged physics/gameplay boundary slots.

Normal and replay gameplay both call the participant's same `simulate_tick()`;
force integration uses the normal native RigidBody3D path and explicitly selected
input. Gameplay includes a drive accumulator and tick count that affect subsequent
forces. The manager restores those values along with the starting physics snapshot.

For every replayed tick, the test compares callback order/eligibility and the
resulting transforms, linear/angular velocity, sleeping state, wrapper force and
gameplay state to the original authoritative reference boundaries. The final
boundary has no historical callback event. Its ordinary flush must match the
reference exactly, and eight subsequent automatic ticks must advance once each
and continue matching the reference. A synthetic live Input action stays pressed
through replay, independently of the selected historical inputs.

Passing equivalence cases include 50 historical ticks, 70 ticks starting at the
initial boundary, 40 ticks starting while sleeping (with later waking), all 240
retained ticks, and a nonzero logical tick origin. The remaining cases exercise
session/order/history failures and clean stopped-world behavior.

A separate temporary project sets a supported four-contact capacity. Two bodies
start above three unchanged static slabs; predicted input keeps them clear, while
corrected historical input drives them into contact during manual replay. The
resulting real Jolt update error is propagated, stops physics/gameplay, leaves
inspection and an unaffected ordinary world responsive, and exits cleanly. This
failure case has different reference geometry and is a failure-isolation check,
not a successful replay-equivalence case.

Run on Windows or Linux after installing the extension:

```sh
python scripts/test-rollback-replay.py /path/to/godot-4.6
python scripts/test-rollback-replay.py /path/to/godot-4.6 --scenario missing_final_capture --repeat 10
```

The runner checks both process exit and explicit pass markers, rejects script
errors, and saves logs under `build/rollback-replay-tests`. It creates disposable
projects for capacity tests without changing the examples configuration.

One local EditorDebug run measured approximately 35 ms for 50 replay ticks and
152 ms for 240 ticks, including test comparisons, callback traces, shared gameplay
and snapshot replacement. These are observations, not a production replay budget.
Release-build profiling and cost/memory work remain necessary before gameplay
integration; a full-window correction can visibly stall rendering at this cost.

The minimal fixed-topology scope, native cached-inertia limitation, and presentation
restrictions from Phase 3 still apply. Linux/SteamOS/Bazzite runtime validation,
cross-platform determinism, network protocol/policy, a reusable production manager,
forklift gameplay, and broader callback support remain later work.
