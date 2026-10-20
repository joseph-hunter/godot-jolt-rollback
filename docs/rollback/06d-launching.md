# Phase 6D — Rollback launching

Implemented October 19, 2026 in the companion game. See the
[launching guide](../../../construction-man/testinghall/rollback_lab/launching.md)
for simulation details, fixed fork collision limits, automated checks and the
PC/Deck retest checklist.

The previous movement-only Steam build was tested by the user between Windows PC
and Steam Deck running Proton: ticks advanced, corrections occurred, maximum
reported span 23 ticks, and controls felt responsive. This is not native Linux
validation or a performance acceptance benchmark.

The launch milestone adds tick-driven attack eligibility/cooldown, historical hit
queries, deterministic launch impulses, derived visual arm animation and sound
deduplication to the existing local and Steam playtest. It changes no native API:
the physical fork shapes remain fixed, retaining the extension's immutable
collision-configuration contract. Damage, destruction, detached parts, respawn and
production match lifecycle remain future work. Validate launching on both actual
machines before broadening that scope.
