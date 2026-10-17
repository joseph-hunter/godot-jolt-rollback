# Rollback architecture and implementation roadmap

[Documentation index](README.md)

Status: proposed for review  
Date: October 11, 2026  
Target: forklift fighting game using a fork of vanilla Godot Jolt

## 1. Objective and scope

Implement rollback physics without initially modifying or recompiling Godot itself. Extend vanilla Godot Jolt with physics snapshots, restoration, explicit stepping, and a correction entry point at the physics server's `sync()` boundary. A GDScript rollback manager coordinates gameplay state, input history, and replay.

This is a fresh design. Existing rollback code is outside this specification and must not be treated as an implementation foundation or constraint.

Preserve ordinary Godot Jolt behavior for worlds that do not opt into rollback. Reuse the backend's simulation and callback machinery wherever possible. An engine fork is not a prerequisite; feasibility of the proposed callback boundary must be demonstrated before making that decision.

Initial scope is a fixed-timestep, fixed-topology physics world: participating bodies, shapes, and joints remain present and retain compatible configuration throughout the replay window. Spawning, destruction, topology changes, navigation replay, and arbitrary SceneTree lifecycle replay are later work.

### Accepted proof-of-concept requirements

The following decisions govern the first implementation and narrow the broader architecture described below:

- Use two simple interacting rigid-body cubes or spheres, not forklift gameplay. Replay both bodies together in one physics space. Static collision geometry remains unchanged. Whole-world rollback is the longer-term goal.
- Target Godot 4.6 and native Windows/Linux builds, including SteamOS and Bazzite. Pin exact runtime and dependency revisions in the implementation audit. Phase 5 provides the reusable manager for the two-body proof of concept; forklift integration and broader acceptance checks follow later.
- Keep gameplay state minimal, but save any mutable values introduced by the test that influence future simulation.
- Support and verify `_integrate_forces()` during normal execution and replay. Body/node state synchronization remains required infrastructure. Other user-facing physics event callbacks, area events, navigation, and dynamic topology are outside the first proof of concept.
- Broader callback support is an important future requirement, not permanently excluded. Keep callback delivery structured so these features can be added without redesigning the tick boundary.
- Run physics at 120 Hz with fixed time scale `1.0` for the initial test.
- Retain a rolling history of 240 simulation ticks using ring-buffer storage: nominally two seconds at 120 Hz. Define tick indices explicitly. Replaying all 240 retained input ticks requires the starting state plus each resulting boundary, so provide 241 boundary snapshot slots, or an equivalent layout that preserves the starting boundary. Ring wrap must never silently resolve an overwritten tick to a newer snapshot.
- Enable Jolt's cross-platform determinism build option from the start. Full deterministic physics is a top-level goal. The flag is necessary configuration, not proof of deterministic gameplay, extension behavior, or all platform combinations; validate the intended targets separately.
- If correction cannot be completed, stop advancement of the affected simulation and report an explicit error. This includes unavailable history, incompatible or failed restoration, missing required input, and replay failure. Prevent the later automatic server step from advancing a failed world. Keep the application responsive so the error can be inspected.
- Initial correction tests may inject known inputs/state locally; full network protocol implementation is not required to prove restoration and replay. Authoritative network snapshot encoding and the server's late-input policy remain separate protocol decisions.

Proof-of-concept success means a corrected replay matches a reference simulation for these two interacting bodies and their minimal gameplay state, with correct force-integration execution and no duplicate stepping. It does not yet establish production forklift rollback or cross-platform determinism beyond the tested builds.

## 2. Ownership

| Component | Responsibilities |
|---|---|
| Physics GDExtension | Own physics spaces and their backend state; save/restore physics snapshots; preserve or rebuild relevant extension state; deliver physics callbacks; expose explicit per-world stepping; enforce exclusive stepping and safe access. |
| Rollback manager | GDScript node, optionally an autoload; own simulation tick numbering, input history, gameplay snapshots, correction requests, replay ordering, and participant registration. |
| Gameplay participants | Forklift and other simulation nodes; own gameplay state and shared simulation logic; use explicitly selected tick input during normal execution and replay. |
| Godot outer loop | Continue normal timing, SceneTree processing, rendering, audio, and engine bookkeeping. It does not schedule historical replay ticks. |

A physics space is the unit of restoration and stepping. Bodies interacting in that space must be replayed together. A participant must not independently step the shared world.

The manager does not transfer all its histories or gameplay code into C++. The extension invokes a registered GDScript callable synchronously at its correction boundary. During that callback the manager accesses its own histories and calls the extension's physics operations.

## 3. Normal physics lifecycle

The existing outer order remains:

```text
Buffered input delivery
Interpolation preparation
PhysicsServer3D.sync()
PhysicsServer3D.flush_queries()
SceneTree.physics_process(delta)
Navigation physics processing, if enabled
Deferred work
PhysicsServer3D.end_sync()
PhysicsServer3D.step(delta)
Deferred work and iteration_end()
```

`sync()` and `end_sync()` are backend access boundaries, not network operations. A synchronous stepping backend may implement them as no-ops. Worker threads can still run inside a synchronous step: the important guarantee is that required jobs have completed when the step returns.

`flush_queries()` delivers physics callbacks, including eligible body force-integration and state-synchronization callbacks and area events. It can execute gameplay code and mutate simulation state. It does not itself select keyboard or controller input.

`SceneTree.physics_process()` dispatches node processing. Calling a participant's gameplay method directly does not reproduce the full SceneTree lifecycle.

`step(delta)` performs the complete backend step, including extension pre-step work, the Jolt update, extension post-step work, and required job-system handling.

## 4. Correction entry point

The manager receives network data and records a pending correction through an exposed extension API. Submission queues work; it does not immediately restore or step the world.

At the next physics-server `sync()`:

1. Establish safe access and complete any outstanding physics work.
2. Identify pending corrections for registered worlds.
3. Invoke each affected world's registered manager callback synchronously.
4. Let the manager restore and replay through the extension APIs.
5. Return only after the corrected world, gameplay state, and callback bookkeeping are consistent.

The outer loop then continues with normal `flush_queries()`, gameplay processing, and stepping.

Input delivery occurs before `sync()`. Therefore this boundary precedes normal physics callbacks, but not every possible gameplay callback. Participating gameplay must not make untracked simulation changes from live input handlers; handlers may collect input for later ticks.

Never recursively enter the rollback-triggering `sync()`. Internal replay synchronization operations, if needed, are separate functions.

## 5. Tick and snapshot boundary

Use an explicit logical simulation tick independent of Godot's frame counters.

Define `B[t]` as the state immediately before the callback delivery and gameplay processing for tick `t`, after the previous physics step has completed. The physics snapshot includes or reconstructs the pending callback state associated with that boundary. The corresponding gameplay snapshot is captured at the same boundary, before those callbacks execute.

```text
B[t]
    Deliver physics callbacks for this boundary
    Run gameplay for tick t using input I[t]
    Step physics by fixed delta
B[t + 1]
```

For normal execution, capture this boundary inside the extension's sync-stage coordination, before ordinary query flushing. The manager must observe tick completion and maintain matching physics and gameplay snapshots.

This boundary is a proposed contract. Confirm it against vanilla Jolt callback behavior in the first implementation phase. If it cannot be represented reliably, revise the boundary before implementing replay, rather than silently mixing snapshot phases.

## 6. Rollback lifecycle

Suppose `B[101]` is the current boundary and corrected input begins at tick 96:

```text
Outer sync():
    Restore physics snapshot B[96]
    Restore gameplay snapshot B[96]
    Restore/rebuild callback bookkeeping for B[96]

    For t = 96 through 100:
        Select input I[t], incorporating corrections
        Deliver required physics callbacks for B[t]
        Run participant gameplay for tick t
        Explicitly step the world by fixed delta
        Capture corrected physics and gameplay snapshot B[t + 1]

    Return at corrected B[101]

Normal flush_queries():
    Deliver callbacks for corrected B[101]
Normal gameplay processing:
    Simulate tick 101
Normal physics step:
    Advance to B[102]
```

The ending boundary is exclusive: replay `[start_tick, end_tick)` and return at `B[end_tick]`. Restoring physics does not restore gameplay automatically. Restore the starting snapshot once; subsequent ticks build on corrected results.

Inputs may be authoritative, locally known, or predicted. Corrections replace invalid input entries. Replay must use the original timestep and relevant configuration for each tick; initially require a constant timestep and time scale throughout the history window.

## 7. Shared gameplay and force integration

Normal and replay execution use the same gameplay calculations. Suspension, acceleration, steering, and other forklift behavior must not have independently maintained replay implementations.

Illustrative participant interface:

```gdscript
func _physics_process(delta):
    simulate_tick(rollback_manager.input_for(self), delta)

func simulate_tick(tick_input, delta):
    update_suspension(delta)
    update_drive(tick_input, delta)
    update_steering(tick_input, delta)

func _integrate_forces(body_state):
    integrate_simulation(body_state, rollback_manager.input_for(self))
```

These functions are conceptual. The manager selects the correct input context before normal `flush_queries()` as well as before replay callbacks. During replay it calls `simulate_tick()` explicitly; ordinary SceneTree processing resumes only after replay returns.

Replay callback delivery should reuse the registered force-integration callback path where feasible. A separate force-integration helper is optional. Calling `simulate_tick()` alone does not trigger `_integrate_forces()`.

Callback eligibility is part of correctness: do not indiscriminately invoke every node's integration callback. Sleeping bodies, pending synchronization, and restored eligibility must reproduce the intended normal behavior.

Simulation methods must use the manager's input context or explicit input arguments, not global live `Input` queries during replay. Replay modifies the restored live simulation state while leaving keyboard/controller input state untouched.

Do not suppress callbacks that affect simulation merely because execution is replaying. Route sound, particles, camera effects, and other presentation-only consequences through a mechanism that suppresses or reconciles duplicate historical effects.

## 8. Replay query delivery

Provide a per-world replay callback-delivery operation using the existing backend mechanisms. Its differences from ordinary flushing are world selection, controlled tick context, replay mode, and delivery ownership—not a new input parser.

Requirements:

- Deliver state needed by gameplay before that gameplay reads it.
- Preserve normal callback order and eligibility for the supported simulation.
- Restore or rebuild pending events from the selected starting boundary.
- Remove invalid notifications from the abandoned timeline.
- Do not deliver the final boundary's callbacks during replay and again during the outer normal flush.
- Ensure body-to-node synchronization exposes restored state correctly, including bodies that would not otherwise request a synchronization callback.
- Guard against reentrant restore/step requests during callback dispatch.

In the proposed boundary model, replay delivers callbacks for `B[start]` through `B[end - 1]`. It leaves the callbacks for `B[end]` for normal flushing after `sync()` returns.

## 9. Snapshots and restoration

Physics snapshots must cover enough state to reproduce future behavior. Jolt's recorder is a candidate for backend state, but its precise coverage must be verified for the pinned dependency version.

Audit additional state outside the Jolt recorder, including forces and kinematic targets held by wrappers, contact/overlap bookkeeping, area events, callback eligibility, cached values, and step metadata. For each item, specify whether it is immutable within the replay window, saved/restored, rebuilt, or safely discarded.

Gameplay snapshots include every mutable value affecting future simulation: for example suspension smoothing, drivetrain state, cooldowns, and deterministic random state when used. Stable participant identifiers link histories to objects.

Snapshots are owned handles scoped to a world and configuration generation. Validate the world, tick, and compatibility before restoration. A failed restore can leave partial mutation; stop advancement and require a known-good reset rather than continue with uncertain state.

Restoration must not occur while physics jobs or callbacks are operating on the world. Do not mutate topology while snapshots requiring the old topology remain replayable in the initial scope.

## 10. Explicit stepping and ownership

Expose a manual step operation for one selected world. Reuse the complete backend step implementation; do not duplicate the solver or call only its lowest-level update function.

Two advancement modes are distinct:

| Mode | Normal advancement | Historical replay |
|---|---|---|
| Automatic with correction support — initial design | Outer server `step()` advances the world once per scheduled tick | Explicit steps run inside the sync-stage correction callback |
| Fully manual — optional later mode | Controller performs every step; outer stepping skips the world | Controller performs replay steps too |

Initial implementation uses the first mode. Historical replay reaches the current boundary and does not also execute the upcoming normal tick. The later outer `step()` therefore advances that new tick exactly once.

Manual stepping outside a controlled correction session is restricted initially. A fully manual mode needs a separate ownership contract and should not be implicitly enabled by exposing a method.

## 11. Proposed extension interface

API names are illustrative, not existing Godot methods.

| Operation | Contract |
|---|---|
| `register_world(space, manager_callback)` | Associate a world with its manager and lifecycle callback. |
| `request_correction(space, request_id)` | Mark correction pending; manager retains input/gameplay data. |
| `capture_physics(space, tick)` | Capture the agreed boundary and return a validated snapshot handle. |
| `restore_physics(space, snapshot)` | Restore compatible backend and extension state at a safe boundary. |
| `flush_replay_callbacks(space)` | Deliver that world's callbacks using the manager's selected tick context. |
| `step_manual(space, delta)` | Execute one complete backend step during an authorized simulation session. |
| `release_snapshot(handle)` | Release history storage. |
| `unregister_world(space)` | Cancel pending work and detach manager ownership safely. |

The manager callback receives an explicit context distinguishing normal-boundary preparation from a correction session. Callback registration must validate lifetime. Multiple corrections arriving before sync are coalesced or queued by a documented policy, typically replaying from the earliest affected retained tick.

## 12. Implementation plan

### Phase 1 — Establish the vanilla lifecycle — Complete

Completed October 11, 2026. Pinned sources, synchronous stepping guarantees, the pre-callback boundary, callback eligibility, and snapshot coverage policies are documented in [the lifecycle audit](01-02-lifecycle-and-boundaries.md). Cross-platform runtime validation remains outstanding.

Pin Godot, godot-cpp, and Jolt versions. Trace synchronization, body callbacks, force integration, area notification queues, and the complete stepping path. Confirm synchronous completion and identify state outside the backend recorder. Document the exact snapshot boundary and callback eligibility rules.

Deliverable: lifecycle trace and snapshot coverage inventory. No rollback behavior yet.

### Phase 2 — Add boundary coordination — Complete

Completed October 11, 2026. The lifecycle audit reports all 13 boundary-coordination scenarios passing on the pinned Windows runtime. Registration, sync-stage manager dispatch, correction notification, and failure handling are implemented. Physics/gameplay snapshot capture and restoration remain Phase 3 work; correction requests currently stop the world with an explicit unsupported-restoration error.

Expose world registration and pending correction requests. Add synchronous manager notification at sync. Establish normal tick input context before flushing, identify matching gameplay/physics boundaries for later snapshot capture, and guard against reentrancy and destroyed participants.

Deliverable: a manager that observes boundaries and receives correction notifications while ordinary physics behavior remains unchanged.

### Phase 3 — Implement snapshots and safe restoration — Complete for the minimal world

Completed October 12, 2026. Restricted fixed-topology capture/restore, 241 boundary slots, validated handles, wrapper callback eligibility, restore-only node synchronization, participant failure control, and Jolt update-error propagation are implemented. All 14 snapshot scenarios and the original 13 boundary scenarios passed on Windows/Godot 4.6. See [the snapshot implementation](03-snapshots.md) for scope, APIs, and the native cached inverse-inertia limitation. Replay and Linux runtime validation remain outstanding.

Implement backend capture/restore plus the extension-state policy from Phase 1. Add compatibility validation, memory limits, handle lifetime, and failure handling. Ensure restored state is visible to gameplay without accidentally consuming the boundary's callbacks twice.

Deliverable: repeatable restore at a documented boundary in a fixed-topology world.

### Phase 4 — Implement explicit replay stepping and callback delivery — Complete for the minimal world

Completed October 13, 2026. Correction callbacks can restore and replay up to 240 retained ticks synchronously, using complete per-world steps and the existing callback path. Corrected boundaries match a reference that used corrected inputs from the beginning, including gameplay state and callback traces. Final callbacks remain pending for normal flushing and the upcoming automatic tick advances exactly once. All 21 replay scenarios, the 14 snapshot scenarios, and the 13 boundary scenarios passed on Windows/Godot 4.6; ten repeated failure/shutdown stress runs also passed. See [the replay implementation](04-replay.md). Linux/cross-platform validation and production replay budgets remain outstanding.

Expose the complete per-world step path and controlled replay flushing. Preserve job handling, callback order, eligibility, and final pending events. Retain ordinary stepping for the upcoming normal tick and unaffected worlds.

Deliverable: a manually replayed physics sequence with consistent callback behavior.

### Phase 5 — Implement the reusable GDScript manager — Complete for the minimal world

Completed October 13, 2026. The reusable per-space manager owns tagged input/gameplay histories, stable participants, correction coalescing, replay, presentation suppression, and failure handling. All 16 manager scenarios and the existing 48 boundary/snapshot/replay scenarios passed on Windows/Godot 4.6. The executable two-body fixture uses the shared participant contract against an authoritative reference. See [the manager implementation and integration guide](05-manager.md). Forklift integration remains deferred under the accepted proof-of-concept scope.

Build tick/input histories and gameplay snapshots. Extract shared simulation calculations from normal callbacks as needed. Implement correction selection, restoration, input-context switching, replay, and corrected snapshot replacement. Separate presentation effects from simulation callbacks.

Deliverable: reusable participant simulation runs identically in normal and replay modes from the same state/input. Apply this contract to forklift suspension and drive logic in a later milestone.

### Phase 6 — Verify network corrections and supported limits

Integrate authoritative input or state corrections, retained-history limits, and recovery when the starting tick is unavailable. Profile replay cost and memory. Do not claim deterministic network behavior solely from successful local restore tests.

Deliverable: demonstrated correction handling under delayed and reordered network input, with supported platform/build limits documented.

The current follow-on sequence is [Phase 6B: performance profiling and necessary
optimization](06b-performance-plan.md), followed by [Phase 6C: a movement-only
multiplayer playtest with real players](06c-real-player-playtest.md). The latter
connects the game's input transport to rollback and tests separate machines under
actual network conditions. Automated localhost tests are its foundation; combat
is excluded from the first player playtest. See the [phase index](README.md) for
current evidence and scope.

## 13. Acceptance checks

1. Worlds not registered for rollback retain ordinary physics and callback behavior.
2. Save a boundary, advance with recorded inputs, restore, and repeat: compare per-tick physics and gameplay state under the supported build configuration.
3. Correct a past input and replay: results match a reference run that used the corrected input originally.
4. Exercise suspension, acceleration, steering, body collisions, sleeping/waking, and area transitions.
5. Verify force-integration execution order and eligibility, with no duplicate final-boundary delivery.
6. Confirm live input state is unchanged by replay.
7. Confirm each replay tick steps once and the subsequent normal tick steps once.
8. Confirm gameplay observes restored transforms/state before using them.
9. Confirm historical presentation effects are suppressed or reconciled while simulation consequences remain active.
10. Reject incompatible snapshots, reentrant operations, stale handles, and corrections outside retained history safely.

Use numerical state comparisons and callback traces as well as serialized backend comparisons. Byte equality alone is not a complete gameplay or callback correctness check. Cross-platform determinism requires separate validation.

## 14. Decisions remaining before implementation

- Confirm the proposed pre-callback snapshot boundary is representable for the pinned vanilla backend.
- Determine complete recorder coverage and the extension state that needs additional restoration.
- Select the supported force-integration, area, and body-contact callback behavior during replay.
- Choose authoritative input correction, authoritative state correction, or both, and define snapshot compatibility for network state.
- History size is fixed initially at 240 ticks in a ring buffer; correction failures stop simulation with an error. Choose a replay performance budget as measurements become available.
- Specify how interpolation/presentation is reconciled after correction without replaying the entire SceneTree lifecycle.

The first implementation milestone is proving boundary capture, restoration, and callback delivery with a minimal world. That evidence determines whether extension-only integration is sufficient before committing to the full forklift simulation.
