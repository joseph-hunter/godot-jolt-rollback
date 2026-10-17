# Phases 1–2 — Lifecycle audit and boundary coordination

[Documentation index](README.md)

Implementation baseline: October 11, 2026. The initial milestone is two interacting
rigid bodies at 120 Hz, time scale 1.0, on Godot 4.6. Forklift gameplay, area events,
navigation, and topology changes are subsequent milestones.

## Pinned sources and validation targets

| Component | Revision |
|---|---|
| Godot runtime | `4.6.stable.official.89cea1439` (`4.6-stable`) |
| godot-cpp | `19a7c15763511e633f76759372d5f39ffa38da7c` |
| Jolt | `39443fca4927ef98e88e436a503139d4752871f2` |
| mimalloc | `fbd8b99c2b828428947d70fdc046bb55609be93e` |

The dependency pins remain in `cmake/GodotJoltExternal*.cmake`. The pinned
godot-cpp fork generates bindings from the Godot 4.3 API; it has not been upgraded
to 4.6 bindings. The methods used by this milestone were exercised on the pinned
4.6 runtime. This verifies that subset of the extension interface, not every
backend feature on 4.6. An upgrade requires checking the fork's build integration
and physics-server API changes rather than replacing the pin blindly.

First validation targets are native Windows x64/MSVC and Linux x64/GCC or Clang,
with SteamOS and Bazzite explicitly included in runtime validation. Only Windows
has been exercised locally so far. Cross-platform determinism remains unverified.
The default `GDJ_CROSS_PLATFORM_DETERMINISTIC` is now `ON`; registration rejects
libraries compiled without `JPH_CROSS_PLATFORM_DETERMINISTIC`. Existing CMake
caches must be explicitly reconfigured to `ON`, including Jolt's external build.

## Outer loop and safe access

Godot 4.6's [main loop](https://github.com/godotengine/godot/blob/4.6-stable/main/main.cpp)
prepares interpolation, calls server sync and query flush, runs physics processing
and navigation, flushes deferred work, ends sync, and steps physics. Input flushing
can precede this sequence. Historical replay must therefore execute synchronously
inside sync and leave the upcoming normal tick to the outer loop.

In this backend, `_step()` wraps each `JoltSpace3D::step()` with job-system
`pre_step()` and `post_step()`. The space performs wrapper pre-step, Jolt
`PhysicsSystem::Update`, wrapper post-step, and metadata updates. Jolt's update
waits for its barrier before returning; the job system then reclaims completed
jobs and their worker tasks. There is no asynchronous physics step outstanding
when the following `_sync()` begins. Phase 4 stress testing identified a distinction:
the solver barrier finishes before a worker's profiling/refcount tail necessarily
does. `post_step()` now joins that trailing cleanup before draining completed jobs,
and the job-system destructor drains once more. This fixes an intermittent shutdown
assertion after replay failures. Simulation-state completion was synchronous;
worker lifetime completion is now explicit too. Internal parallel jobs do not
require an engine fork or asynchronous correction protocol.

At Phase 1 the space step reported capacity errors as warnings and returned
`void`. Phase 3 now returns Jolt's error flags and stops registered worlds on any
update error. The exact pinned update-error assertion has a scoped nonfatal path
in debug builds so those flags can reach the coordinator; other assertion handling
and unregistered worlds retain their previous behavior.

The newly added `_sync()` invokes registered managers before ordinary query
flushing. Rollback APIs require the main thread. Registration/unregistration are
restricted to an idle server, and callback dispatch rejects recursively requested
corrections and server lifecycle operations. Manager callbacks cannot retain
direct physics state objects beyond their supported callback lifetime.

## Boundary and callback eligibility

`B[t]` is representable as backend and wrapper state after the previous complete
step and before query delivery. Snapshot capture must include pending wrapper
state; Jolt's recorder alone does not represent this boundary.

`JoltSpace3D::call_queries()` acquires all bodies, delivers rigid-body callbacks,
then area callbacks, and releases access. It skips all callback delivery until
the space has stepped once. This initial boundary is a real distinction: the
first normal tick need not receive `_integrate_forces()`.

`JoltBodyImpl3D::call_queries()` checks `sync_state`. If set, it invokes the
registered custom force-integration callback, then state-synchronization callback,
and clears the flag. Rigid-body pre-step queues synchronization only for bodies
that were active when force integration ran. Activation during a step also queues
synchronization. A body that falls asleep during a step can still have a pending
callback at the next boundary. Current sleeping state alone cannot reconstruct
eligibility. Kinematic movement/contact-reporting has additional enqueue paths.

The state-synchronization callback updates Godot node state before ordinary
gameplay processing. Restoration must additionally synchronize bodies whose
snapshot has no pending callback, without inventing a force-integration callback.
Phase 3 found that Godot 4.6's native `RigidBody3D::_body_state_changed()` also
invokes the script `_integrate_forces()` virtual. Calling this native callback
for restore-only synchronization therefore invents integration. The implemented
minimal path uses public node cache setters with backend writeback suppressed;
see [the snapshot implementation](03-snapshots.md) for the
supported fields and the native inverse-inertia cache limitation.
The future replay flush should reuse these paths and preserve their order, while
leaving the final boundary's callbacks for ordinary flushing.

## Snapshot coverage and proposed policies

These policies were the Phase 1 inventory. Phase 3 implements the restricted
capture/restore contract documented in [the snapshot implementation](03-snapshots.md).

| State | Coverage / restoration policy |
|---|---|
| Jolt global state | `PhysicsSystem::SaveState(All)` includes previous step delta and gravity. Restore these. |
| Body transforms and activation | `BodyManager` records body IDs and active flags; `Body` records position/rotation. Restore through the full system recorder, which updates broadphase bounds. |
| Motion state | `MotionProperties` records velocities, accumulated force/torque, sleep-test spheres/timer, allow-sleep flag, and double-precision sleep offset when enabled. Restore these. |
| Backend contacts and constraints | Full system recorder includes contact-manager and constraint-manager state. Retain solver contact caches even when no user-facing contact callbacks are enabled. |
| Body IDs, shapes, modes, mass/inertia, material/filter settings | Not all configuration is recorded. Hold immutable in the proof of concept and reject incompatible topology/configuration generations before mutation. |
| Wrapper `sync_state` | Save/restore exactly; do not derive from current activation. |
| Wrapper constant force/torque, gravity, total damping | Save/restore mutable values. Jolt's per-step force accumulator does not cover constant wrapper forces or the values exposed through direct state. |
| Wrapper kinematic target and surface velocities | Save/restore before supporting kinematic/static motion. The first replay test uses rigid bodies and unchanged static geometry. |
| Callback objects/userdata | Stable registrations within the window; mutable userdata affecting gameplay must belong to gameplay snapshots. Validate owner lifetimes. |
| Wrapper contact buffers and count | Save/restore if contact reporting is enabled. Initially require contact reporting off; physical collisions still occur through Jolt. |
| Extension contact listener | Persistent manifold map and overlap/enter/exit sets are outside the recorder. With no contact reporting or user areas, these paths are unused for simulation; enforce that restriction for the first snapshots. Add restoration before broadening support. |
| Area overlap membership, pending events, body area list | Not covered by the recorder. Exclude user areas from the initial replay world; do not silently discard simulation-affecting area state. |
| Space `last_step`, `has_stepped`, optimization count | Save/restore boundary metadata, including the initial callback skip. Body-add optimization metadata is constant after fixed topology is established. |
| Shape caches and previous shape references | Shapes/configuration immutable after initial setup. Post-step clears previous shape references. Reject snapshots taken during incompatible configuration changes. |
| Job system and body-access locks | Never serialize live jobs/locks. Capture/restore only after completion and outside query dispatch. |
| Editor debug contacts/timings | Presentation/debug state; discard or refresh after correction, never treat as simulation authority. |
| Gameplay and random state | Manager-owned snapshots at the same pre-callback boundary. Save every mutable value used by shared simulation logic. |

Recorder restoration can mutate global/body state before failing on later data.
Snapshots must be owned, world-scoped handles with tick and generation validation;
failure must leave the world stopped until destruction and a known-good reset.
There must be 241 boundary slots for 240 retained input ticks, with exact tick
tags checked before reading a ring slot. No recorder bytes should be accepted
as an authoritative network snapshot without a separate validated protocol.

## Boundary coordination API implemented now

All methods are on the selected `PhysicsServer3D` extension instance:

| Method | Current behavior |
|---|---|
| `rollback_register_world(space, callback) -> bool` | One synchronous manager per world. Validate callable, configuration, build flag, and safe access. Does not change ordinary callback eligibility. |
| `rollback_request_correction(space, request_id) -> bool` | Queue notification for the next active sync; never invoke the manager immediately. Nonnegative IDs. Coalesce metadata as latest ID and number of queued requests; the manager owns earliest affected tick and actual input corrections. |
| `rollback_unregister_world(space) -> bool` | Detach ownership and pending notification at an idle boundary. Does not clear a failed world's stop state. |
| `rollback_fail_world(space, error)` | Persist the first error and prevent subsequent callbacks and automatic steps for that world. Other worlds continue. |
| `rollback_get_world_status(space) -> Dictionary` | Registration, active/failure state, error, completed automatic steps since registration, and pending request metadata. |

The callback receives a dictionary with `kind` (`normal_boundary` or
`correction_pending`), `space`, `completed_steps`, `delta`, `request_id`,
`request_count`, and `replay_available`. It must return boolean `true` on successful
normal preparation. False, a nonboolean result, or an expired callback owner stops
the world. `completed_steps` is diagnostic progress relative to registration;
the manager owns logical tick numbering and histories.

At the boundary-coordination milestone `replay_available` was always false. A queued correction notified
the manager, then stops the world with an explicit unsupported-restoration error,
even if the callback returns true. Phase 3 now advertises `restoration_available`
and implements capture/restore. Phase 4 now advertises `replay_available=true` and
requires queued correction callbacks to complete a controlled replay session.
Callbacks that return without completing one stop the world explicitly. See
[the replay implementation](04-replay.md). The API distinguishes
pending notification from a future authorized
correction session so that those operations can be added without moving the
boundary.

Stopping physics does not stop SceneTree processing. Participants must honor the
manager's failure state, and presentation/UI should remain responsive. This
milestone exposed failure status without suspending gameplay nodes. Phase 3 adds
explicit participant registration and disables registered nodes' script process
and input dispatch on failure. Arbitrary signal handlers and external calls still
require a manager failure guard; unrelated UI and worlds continue.

## Verification

`examples/scenes/rollback_poc/boundary-test.tscn` creates two interacting spheres
in a registered world and an identical ordinary reference world. Inputs are
selected inside sync, before `_integrate_forces()`. It compares transforms,
velocities, callback eligibility, node/direct-state synchronization, and exactly
one automatic step per observed boundary. It also checks invalid registration,
inactive worlds, destroyed spaces/owners, reentrant correction submission,
coalesced correction notification, invalid callback results, explicit failures,
configuration changes, and persistent failure after manager detachment.
Sleeping/waking is exercised separately, with callback counts compared to the
ordinary world rather than assuming every body receives one callback per tick.

After installing the editor extension, run from the repository root:

```powershell
./scripts/test-rollback-boundary.ps1 -GodotPath /path/to/Godot_v4.6-stable_win64_console.exe
```

The runner requires both exit success and the explicit per-scenario pass marker;
Godot can otherwise exit successfully after a script parse/runtime error. Negative
scenarios deliberately emit backend errors, then verify the stopped world and
continued advancement of the ordinary world. These tests prove boundary
coordination and failure handling, **not** restoration, corrected replay, or
cross-platform determinism.

Local result: Windows x64 EditorDebug built and installed successfully with
determinism enabled in both the extension and Jolt. All 13 boundary scenarios
passed on `4.6.stable.official.89cea1439`; the normal case observed 91 boundaries
and 90 force-integration callbacks, and the sleeping/waking case observed 146
boundaries and 95 callbacks. Linux/SteamOS/Bazzite runs remain outstanding.
