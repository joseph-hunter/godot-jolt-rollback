# Phase 6G - Fixed-topology contact reporting and damage

October 22, 2026. The companion game's rollback lab now supports collision-impact
health and visual damage with immutable bodies/shapes. See the
[damage guide](../../../construction-man/testinghall/rollback_lab/damage/README.md)
for gameplay rules, snapshot fields, presentation behavior and validation.

Native snapshots retain pending direct-body contact samples and the contact
listener's persistent shape-pair/depth bookkeeping. Capture still requires empty
unflushed listener sample arrays and no area history. Contact report capacity is
part of the immutable configuration signature. Body contact monitoring remains
forbidden: native `RigidBody3D` contact-monitor caches/signals are not restored.
Areas, topology changes, kinematic bodies, joints and integration userdata remain
excluded. Contact sample storage is charged to the existing 64 MiB history budget.

Registered worlds flush shape pairs in stable order; ordinary worlds retain their
previous order. Registration/unregistration enables/disables that ordering.
The new `rollback_supports_contact_reporting()` capability method lets the game
reject old DLLs before enabling this milestone.

The game snapshots health, bounded mesh-hit histories and stable-keyed impact
episodes. Zero health never triggers destruction, detachment, shape disabling,
explosions or respawn. Ordinary damage/destruction remains unchanged. Replay uses
the same native callback and gameplay paths; no damage RPC or wall-clock timer
owns simulated health.

The optimized editor build passed all 64 existing native scenarios. Four new
real-forklift reference cases compare every replayed boundary, including contact
samples and a populated starting contact buffer across ring wrap. Local ENet
convergence/failure checks passed, and the optimized runtime library was rebuilt.
Native Linux and actual PC/Deck damage validation remain outstanding.
