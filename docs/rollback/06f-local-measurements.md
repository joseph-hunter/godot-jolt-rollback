# Phase 6F - Local automated measurements

The companion game has a local-only measurement runner under
`testinghall/rollback_lab/measurement`. It compares 0/2/6 input-delay ticks under
clean, 30 ms jitter and 10% simulated batch loss, with three repetitions by
default. Each local ENet peer reports correctness, replay costs/spans, process
cadence, per-forklift physical correction sizes and input-arrival margins.

See the [measurement guide](../../../construction-man/testinghall/rollback_lab/measurement/README.md)
for commands, definitions, output files and interpretation limits. Production
Steam gameplay logs remain future work; this step does not export/upload a build
or require two physical devices. No native extension API changes.

The first rendered matrix completed 27/27 pairs without confirmed-state
disagreement. Results are recorded in the companion
[baseline report](../../../construction-man/testinghall/rollback_lab/measurement/RESULTS.md).
Two input-delay ticks reduced clean-delivery replay costs relative to zero in
that setup; loss produced larger stalls. This is a single-machine instrumented
baseline, not a Steam/Deck result or a performance acceptance decision.

Follow-on game-side investigations record the
[outgoing queue-wait fix](../../../construction-man/testinghall/rollback_lab/measurement/QUEUE_WAIT_RESULTS.md)
and [startup/tick-alignment experiment](../../../construction-man/testinghall/rollback_lab/measurement/STARTUP_ALIGNMENT_RESULTS.md).
The latter uses calibrated local monotonic clocks and matched current/scheduled
starts. It finds role-associated correction costs can reverse with timeline
lead; a shared startup deadline alone does not reliably maintain alignment.
These experiments change no native API or production startup policy.
