# Phase 5 — Reusable GDScript rollback manager

[Documentation index](README.md)

Phase 5, October 13, 2026. The reusable script is
[`examples/rollback/rollback_manager.gd`](../../examples/rollback/rollback_manager.gd).
It uses the Phase 4 extension APIs unchanged. This milestone covers the accepted
two-body world; forklift suspension/drive integration remains later work.

## Setup and participant contract

Create one manager per physics space, after the bodies enter their world. Start
from `_ready()` or another idle boundary, with Godot 4.6, the **Jolt Rollback
(Extension)** physics server, 120 Hz and time scale 1.0. Participants are fixed
for the lifetime of a registration. IDs are unique StringNames, sorted for stable
gameplay dispatch order. Physics callback order remains the backend's order.

```gdscript
const RollbackManager = preload("res://rollback/rollback_manager.gd")
var rollback

func _ready():
    rollback = RollbackManager.new()
    add_child(rollback)
    assert(rollback.add_participant(&"player_1", $Player1))
    assert(rollback.add_participant(&"player_2", $Player2))
    assert(rollback.start(get_world_3d().space, sample_input))

func sample_input(tick: int) -> Dictionary:
    # Read local input, and use known/predicted remote input here.
    return {&"player_1": local_input(tick), &"player_2": remote_input(tick)}
```

Each participant implements the following methods. `rollback_restore()` and
`rollback_simulate()` must return boolean `true` on success; `false` or a missing
return fails the world. Save every mutable gameplay value affecting later ticks,
including RNG state. Physics transforms, velocities and backend forces belong to
the extension snapshot and should not be duplicated in the gameplay snapshot.

```gdscript
var drive := 0.0
var rollback  # Assigned by the game's setup code.
var participant_id := &"player_1"

func rollback_save() -> Dictionary:
    return {"drive": drive}

func rollback_restore(state: Dictionary) -> bool:
    drive = state.drive
    return true

func rollback_simulate(tick_input, delta: float) -> bool:
    drive = drive * 0.9 + tick_input.throttle
    # Shared normal/replay gameplay calculation.
    return true

func _integrate_forces(state: PhysicsDirectBodyState3D):
    var tick_input = rollback.input_for(participant_id)
    state.apply_central_force(Vector3(tick_input.throttle, 0, 0))
```

The manager disables participants' `_physics_process()` and owns all their tick
dispatch. Do not re-enable that callback or independently call simulation.
Force callbacks remain enabled and use the input selected before flushing.
Input handlers may collect input but must not mutate simulation; `_process()`,
signals, timers, deferred methods, and unregistered children must not independently
advance participating gameplay. Every simulation node needs explicit registration.
Participant methods must not mutate topology, yield, or invoke rollback APIs.
GDScript cannot catch arbitrary runtime exceptions; participants must validate
their own data and report failure through the boolean contract. Treat script errors
as failures during development, as the test runner does.

Inputs and gameplay snapshots contain value data: scalars, Godot math values,
packed arrays, and nested Arrays/Dictionaries up to 32 levels. Objects/Resources,
RIDs, Callables, Signals, cyclic containers, and mutable container dictionary keys
are rejected. Mutable histories (including nested packed arrays) are
deep-copied at capture, submission, selection, and restoration. `input_for()` gives
an owned copy. Participants may return an existing mutable gameplay Dictionary;
later mutation will not change the saved boundary. Dictionaries must contain
exactly one input value for every registered ID; `null` is an explicit value, not
a missing key. Gameplay history size depends on the participant data; the native
64 MiB limit applies to physics history, not GDScript values.

## Normal ticks and corrections

`current_tick` is the selected logical tick, with an optional nonnegative origin
passed to `start()`. At each sync boundary the manager saves physics and gameplay
`B[t]`, selects a complete input frame, and arms one normal gameplay dispatch.
The outer loop delivers eligible force callbacks, the manager calls participants
once, and the outer server advances physics once.

Submit a complete authoritative frame with `submit_input(tick, frame)`. Corrected
past frames replace recorded predictions. Multiple submissions before sync replay
from the earliest changed tick in one session. Last submission wins for each tick;
an identical frame queues no correction. This is an input correction API, not a
network protocol or authoritative state decoder. Batch partial remote updates into
a complete frame in the game's network/input adapter.

Submission must occur on the main thread outside sync coordination and force
callbacks, for example from the game coordinator's `_physics_process()` or idle
network receive handling. Submissions during coordination are rejected. A changed
frame for the currently selected tick is applied by replay at the next sync;
already selected normal input remains stable for its entire tick.

Future frames up to 240 ticks ahead are retained separately and override the input
provider when that tick arrives. The provider is called once for each upcoming tick
without a queued future frame and **never during replay**. Replay uses retained
frames plus explicit replacements; it does not recompute other predictions based
on a corrected frame. An adapter using dependent prediction must submit those
affected frames too. No global Input state is rewritten.

Input history holds 240 tagged ticks and boundary history 241 tagged states.
Correction runs before selection of the upcoming input, preserving the complete
240-tick replay window. Every required input and starting boundary is validated
before restoration. Replay restores physics and gameplay once, then repeats
select input → backend callback flush → shared participant simulation → complete
manual step → corrected boundary capture. The exclusive ending boundary is saved
but its callbacks remain for normal flushing. The subsequent normal preparation
selects live input and the upcoming automatic step advances exactly once.

`present(id, event)` emits `presentation_event` only during normal execution.
Route sounds/particles and other presentation consequences through it; simulation
consequences always execute. On correction completion the manager resets participant
physics interpolation and emits `corrected(start_tick, end_tick)` for any additional
camera/UI reconciliation. Signal handlers must perform presentation only; defer
network submission or topology changes to an idle boundary. This suppresses replay
duplicates but does not undo effects already emitted on the abandoned timeline.

## Failure and lifetime

Missing/stale history, unsupported input/snapshot data, participant failure, and
backend failures stop the affected world. `failed`, `failure_reason`, and the
one-shot `simulation_failed(message)` signal expose the error. The native backend
stops automatic physics and registered script dispatch; the manager gates shared
gameplay and stays alive to inspect failures. Other worlds and UI keep running.
Native errors retain their original diagnostic. Failed worlds require a new
space/reset; detaching does not clear a space's failure.

Before freeing a manager while retaining its space, `await rollback.detach()`.
It waits for an idle `process_frame`, unregisters ownership and releases both
histories. Keep the manager and space alive until it returns. Ordinary physics
continues after detach; participant physics processing stays disabled until the
caller explicitly enables it. Force callbacks still run: remove their manager
dependency or supply ordinary input before freeing a detached manager while
retaining bodies. For complete world teardown detach first, then free
the space and nodes. Freeing a registered manager without detaching is a lifecycle
error: the backend fails the world when its callback owner disappears. Shutdown of
the whole application releases the server's registrations normally.

## Validation and remaining scope

Run the executable integration fixture with:

```text
python scripts/test-rollback-manager.py path/to/Godot_v4.6-stable_win64_console.exe
```

The fixture creates two interacting bodies plus an ordinary authoritative reference
world. It verifies corrected physics, nested mutable and packed-array gameplay state, force callback
order/eligibility, final normal flushing, exact automatic/manual step counts,
reordered/coalesced and repeated correction sessions, copied submission data, provider call counts,
presentation suppression, sleeping/waking, arbitrary tick origin, full 240-tick
replay, ring wrap, unchanged frames, future input, stale/missing/unsupported input,
unsupported snapshots, restore/simulation failure, backend failure, unaffected
reference advancement, and idle detach. Manager tests compare each historical
gameplay tick and callback trace. The lower-level replay suite retains its separate
per-historical-physics-boundary comparisons and native API misuse coverage.

All 16 manager scenarios and the existing 48 boundary/snapshot/replay scenarios
passed on the pinned Windows Godot 4.6 runtime. Linux/SteamOS/Bazzite runtime
validation, cross-platform determinism, production replay budgets, network/state
protocols, forklift gameplay, dynamic topology, and broader callback support remain
outstanding. The existing snapshot restrictions and native cached inverse-inertia
limitation still apply; see [snapshot details](03-snapshots.md)
and [replay details](04-replay.md).
