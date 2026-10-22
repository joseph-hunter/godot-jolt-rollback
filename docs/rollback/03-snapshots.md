# Phase 3 — Snapshot capture and restoration

[Documentation index](README.md)

Implemented October 12, 2026, against the revisions in the
[lifecycle audit](01-02-lifecycle-and-boundaries.md). Windows x64 EditorDebug was rebuilt
and installed into the examples project. All 14 snapshot scenarios and all 13
original boundary scenarios passed on `4.6.stable.official.89cea1439`.

## Contract and supported state

Later extension: [Phase 6G](06g-fixed-topology-damage.md) adds direct-body contact
report buffers and listener bookkeeping. Contact monitoring and area events
remain excluded. The report below retains its original milestone scope.

Capture and restore are allowed only in the selected world's synchronous manager
callback at `sync()`, outside query dispatch, stepping, and nested snapshot
operations. They preserve the pre-callback boundary `B[t]`. A handle names an
owned snapshot and its exact logical tick; it is never a serialized network blob.

The current world may contain rigid/rigid-linear bodies and unchanged static
geometry. Joints, user areas, soft bodies, kinematic bodies, contact reporting or
monitoring, nonempty extension contact/event history, and non-NIL force-integration
userdata are rejected. The backend's empty default-area sensor is included in
Jolt state, while default-area parameters are validated as immutable configuration.

The full Jolt recorder saves backend transforms, velocities, accumulated forces,
activation/sleep state, solver contact caches, and global state. Additional wrapper
snapshots save `sync_state`, constant force/torque, gravity and total damping,
kinematic target/surface velocity fields, and space step/initial-query metadata.
Restoring `has_stepped=false` preserves the initial boundary's callback skip.

Each snapshot retains body IDs, wrapper RIDs, shape references, configuration,
and topology generation. New captures must remain compatible with retained
history. Restore validates the entire world before calling Jolt: topology, shapes,
static poses, body/filter/material/mass/damping configuration, callback registrations,
default-area parameters, and solver settings. Validation failure leaves current
physics untouched and stops the world. Recorder failure after mutation also stops
the world and requires destruction and a known-good reset.

Gameplay state remains manager-owned. The test captures its force-affecting
`gameplay_value` at the same boundary and restores it explicitly. Restoring physics
does not restore arbitrary script fields or the manager's tick counter.

## Restore-only node synchronization

Godot 4.6's native
[`RigidBody3D::_body_state_changed()`](https://github.com/godotengine/godot/blob/4.6-stable/scene/3d/physics/rigid_body_3d.cpp)
dispatches `_integrate_forces()` inside the state-sync callback. The backend's
custom force-integration callback and Godot's script virtual are distinct paths.
Calling the native callback solely to refresh a sleeping body would produce an
extra script integration invocation.

Restore instead refreshes node transform, cached linear/angular velocity, and
sleeping/allow-sleep properties using public setters. Transform notifications and backend
writeback are suppressed for this operation. It does not dispatch the native
state-sync callback, change `sync_state`, emit a synthetic sleeping-change event,
or consume pending simulation callbacks. Ordinary flushing subsequently delivers
exactly the restored eligible callbacks. Tests exercise sleeping snapshots both
with and without a pending callback.

**Supported-field limitation:** Godot exposes no public setter for its private
cached inverse-inertia tensor. The restore-only path cannot refresh that cache;
`RigidBody3D.get_inverse_inertia_tensor()` can retain an abandoned-timeline value
until the next eligible native callback. Simulation that needs inertia immediately
after restoration must read `PhysicsDirectBodyState3D` instead. Contacts/monitoring
are excluded, so their native caches are not used by this proof of concept. This
milestone proves the fields used by the two-body test, not complete restoration of
every native node cache. Broader node support needs an explicit adapter or engine
API decision. Interpolation/presentation reconciliation also remains later work.

## APIs and ownership

| Method | Behavior |
|---|---|
| `rollback_capture_physics(space, tick) -> int` | Capture `B[tick]` in the selected manager callback; return a positive handle or zero on failure. |
| `rollback_restore_physics(space, handle, tick) -> bool` | Validate ownership, exact handle/tick, compatibility and safe access; restore and synchronize supported node fields. |
| `rollback_release_snapshot(space, handle) -> bool` | Release an owned handle on the main thread, outside nested snapshot work/query dispatch/stepping. Return false for unknown or already released handles. |
| `rollback_register_participant(space, node) -> bool` | Register a simulation node at an idle boundary. A node may belong to only one registered world. |
| `rollback_get_world_status(space)` | Now includes snapshot count, charged bytes, and oldest/newest retained tick. |

Per-world storage is a ring with 241 boundary slots (`tick % 241`). Slot overwrite
immediately invalidates the previous handle. Both exact tick and monotonically
allocated handle must match before restore; a wrapped slot can never resolve an
old tick to a newer state. Capture of an existing tick replaces its previous
handle. Unregistering or destroying a world releases its entire snapshot pool.

The per-world history accounting limit is 64 MiB, including recorder data and a
conservative charge for wrapper/configuration metadata and exception arrays.
Shared shape resources are retained rather than copied; this is a history-storage
budget, not an exact allocator or total-process memory quota. Capturing/validating
temporarily allocates another recorder. The two-body tests remain far below the
budget; production replay cost and memory need separate measurement.

At Phase 3 the manager context advertised `restoration_available=true` and
`replay_available=false`. Phase 4 now enables controlled replay; see
[the replay implementation](04-replay.md). Logical tick numbering remains manager-owned;
`completed_steps` continues to count automatic steps since registration even when
an earlier boundary is restored. Local restore experiments use normal-boundary
callbacks, reset logical/gameplay state, and let subsequent ordinary ticks advance.
This is repeatable restoration and continuation, not historical replay within one
sync. Queued correction callbacks must now complete a replay session and leave
the final boundary's callbacks pending for ordinary flushing.

## Failure and gameplay control

Jolt update-error flags now reach the server after complete pre/update/post work
and job reclamation. Any update error in a registered world records an explicit
error, suppresses later query delivery, and prevents later automatic steps.

In the pinned Debug Jolt build, `PhysicsSystem::Update` asserts on those error
flags after its jobs have joined and its locks have been released. The extension
allows only that exact assertion's return path, only during a registered world's
update and only on the calling thread. This lets the error flags stop the world
without crashing the inspection UI. Other assertions and unregistered-world
behavior are unchanged. Future Jolt upgrades must re-audit this source-specific
assertion contract.

Failure disables registered participants' script `_physics_process`, `_process`,
and input/unhandled-input dispatch. It deliberately avoids changing collision
objects' process mode, which can remove bodies and alter topology. Register every
simulation node that runs such updates, including simulation children. The manager
and unrelated UI need not be registered and can continue inspecting the error.
Unrelated worlds continue advancing. Signal-driven or externally invoked gameplay
must still honor manager failure state; no API can interrupt an already executing
GDScript function. A stopped world has no in-place recovery API in this milestone.

## Verification

From the repository root, on Windows or Linux after installing the extension:

```sh
python scripts/test-rollback-snapshots.py /path/to/godot-4.6
```

The runner requires a successful exit and explicit pass marker, rejects script
errors, and saves logs in `build/rollback-snapshot-tests`. The update-error scenario
uses a disposable project with a supported four-contact capacity; the examples
configuration is never changed. Its two rigid bodies contact three unchanged
static slabs, causing a genuine constraint-capacity overflow. The test observes
error flags `4`, continued inspection/reference-world advancement, and stopped
participant gameplay.

The other scenarios cover active and initial boundaries, sleeping bodies with and
without pending callbacks, repeated restore from one recorder, exact numerical
state and force-affecting gameplay continuation, node properties visible before
ordinary flushing, callback traces/eligibility/order, released handles, wrong
tick/world, mass/shape/environment incompatibility, unsupported areas, 241-slot
ring wrap, and unsafe capture outside the manager callback. Rejected restore
attempts are checked for absence of partial physical mutation.

Linux/SteamOS/Bazzite execution, cross-platform determinism, authoritative network
state, and full native-cache support remain unverified. Historical manual replay
has since been verified in Phase 4 for the same minimal world.
