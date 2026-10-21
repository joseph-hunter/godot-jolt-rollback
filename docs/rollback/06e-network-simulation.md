# Phase 6E - Host-configured network simulation

October 20, 2026. The companion game lab now defaults to zero local input delay.
The host may choose 0..24 input-delay ticks, added network delay, jitter and
0..100% simulated packet loss in the lobby. The client receives and acknowledges
the settings before Start; both peers apply the agreed conditions during play.

See the [network simulation guide](../../../construction-man/testinghall/rollback_lab/playtest/network-simulation.md)
for ranges, retry semantics, HUD/log metrics and regression commands.

The simulator delays input batches above the existing transport and approximates
ordered reliable delivery, retaining lost batches for retry. It does not claim to
simulate individual UDP packets or the full Steam/ENet transport implementation.
No native API or physics snapshot contract changes. Damage/destruction remain
outside the milestone. This extends Phase 6C/6D rather than replacing their tests.
