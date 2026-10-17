# Phase 6C — Movement-only multiplayer playtest with real players

[Documentation index](README.md)

Status: controlled ENet playtest implemented in companion game; human/LAN validation pending  
Date: October 16, 2026

## First implementation

The companion game's `testinghall/rollback_lab/playtest/README.md` contains the
Host/Join scene and `run-playtest.py --solo` launcher. One window accepts live
forklift controls; the other can use an optional scripted driver. Both machines
simulate both forklifts through the existing manager. Steam is outside this step.

The initial adapter uses a separate SceneMultiplayer subtree with ENet, a
prepare/ready/start handshake, matching runtime/backend/source fingerprints,
six ticks of local input delay, fixed neutral prediction and reliable ordered
input batches with cumulative acknowledgements. Future remote commands remain
in the adapter so every normal tick still samples local input. Periodic confirmed
physics/gameplay boundary comparisons check convergence. Input storage is bounded;
disconnect, excessive lag, clock divergence and exhausted history stop simulation.
Restarting the scene is the initial recovery policy.

This uses the game's ENet transport technology without migrating its production
lobby/authentication or snapshot-puppet path. It does not yet provide clock
discipline, combat, respawn, Steam transport or production session recovery.
The benchmark's replay stalls remain unresolved; no performance acceptance budget
has been agreed. Automated fixture results do not replace human feel testing or
two-machine validation. See the companion guide for commands and recorded checks.

## Sequence and purpose

Complete [performance profiling](06b-performance-plan.md) first: instrument,
measure an optimized build, agree on a practical replay budget, and address costs
that would disrupt play. Then connect the game's input transport to rollback and
run a movement-only multiplayer playtest with real players on separate machines.

The existing two-process localhost tests establish automated correction and
failure-handling evidence. This next step tests the complete live input path,
actual network connections, responsiveness, forklift interactions and the visual
effects of corrections. It is a controlled playtest milestone, not a claim of
production multiplayer readiness.

## Initial scope

- Two real players control the actual forklifts using live controls rather than
  scripted fixture inputs.
- Each participating simulation replays the interacting forklifts together in
  one physics space, using the existing shared movement code and participant
  contract.
- Exchange tick-numbered inputs, predict missing remote inputs, and submit late
  corrections through the manager. Do not combine rollback-controlled bodies
  with the existing remote kinematic snapshot-puppet path in that world.
- Exercise driving, steering, braking, boost, jumping, flight and forklift
  collisions under the existing movement-only restrictions.
- Observe input response, visible corrections, camera/interpolation behavior and
  replay stalls. Retain timing and correction diagnostics from Phase 6B.
- Keep combat, contact-driven damage, destruction, spawning/respawning and
  changing topology outside this first playtest.

Keep new testing scenes and scripts under the game's
`testinghall/rollback_lab`, organized into a playtest subfolder when implemented.
The automated local and network fixtures remain regression checks.

## Decisions before implementation

Settle how the existing connection/lobby flow starts a rollback session, how
players map to stable participant IDs, how input ticks align between machines,
and which prediction, acknowledgement and retransmission rules the live adapter
uses. The fixture protocol is evidence to build on, not an automatically approved
production transport design.

Define explicit behavior for unavailable history, disconnects and session
teardown. Preserve the current safe stopped-world behavior until a separately
designed recovery policy replaces it. Select the initial supported runtime/build
and machine configurations; cross-platform determinism still requires its own
validation.

## Playtest evidence

Record the tested builds, machines, connection conditions, correction frequency,
replay spans/times and player observations. Verify that both players can control
their forklifts, interact physically, recover from delayed inputs and continue
without duplicate stepping or silent history failures. Compare matching logical
ticks using a diagnostic state comparison whose format is settled during design;
visual similarity alone is insufficient evidence of convergence.

Use the agreed Phase 6B budget to assess performance and collect specific reports
of input delay, snapping, camera jumps and stalls. Feed those findings into the
next plan before broadening to combat, lifecycle changes or more platforms.
