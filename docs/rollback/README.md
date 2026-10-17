# Rollback documentation

Start with the [architecture and roadmap](00-architecture-and-roadmap.md) for the
overall design, then use the phase documents below. File numbers follow the
original implementation phases. Phases 1 and 2 share a document; missing numbers
or letters do not imply missing implementations.

## Phase index

| Phase | Topic | Document | Status / scope |
|---|---|---|---|
| Overview | Architecture, ownership, tick boundaries and original plan | [00 — Architecture and roadmap](00-architecture-and-roadmap.md) | Design reference; some original decisions and milestone descriptions are historical |
| 1 | Audit the vanilla physics lifecycle | [01–02 — Lifecycle and boundaries](01-02-lifecycle-and-boundaries.md) | Complete for the pinned Windows minimal-world test |
| 2 | Coordinate managers at the sync boundary | [01–02 — Lifecycle and boundaries](01-02-lifecycle-and-boundaries.md#boundary-coordination-api-implemented-now) | Shares the Phase 1 audit; registration, dispatch and failure handling |
| 3 | Capture and restore physics snapshots | [03 — Snapshots](03-snapshots.md) | Complete for the restricted fixed-topology world; restrictions and native-cache limitation documented |
| 4 | Deliver callbacks and explicitly replay historical ticks | [04 — Replay](04-replay.md) | Complete for the minimal world; includes ordering and reference-test evidence |
| 5 | Reusable GDScript manager and participant contract | [05 — Manager](05-manager.md) | Implemented; use this for integration and API/lifetime guidance |
| 6A | Test network input corrections and retained-history failure | Companion game network guide, below | Windows localhost tests implemented; no separate extension-side phase report yet |
| 6B | Instrument and profile replay performance | [06B — Performance plan](06b-performance-plan.md), [benchmark results](06b-benchmark-results.md) | Initial instrumentation and optimized baseline implemented; budgets and optimization pending |
| 6C | Movement-only multiplayer playtest with real players | [06C — Real-player playtest](06c-real-player-playtest.md) | Controlled ENet Host/Join lab implemented; human feel and two-machine LAN validation pending |

The A/B/C labels distinguish workstreams within the original Phase 6. They do not
renumber the roadmap or establish a new sequence of completed phases.

The agreed next sequence is **performance work first, then a movement-only
multiplayer playtest with real players on separate machines**. The localhost
network fixture supplies automated correctness evidence; the player playtest
will assess responsiveness, collisions and visible corrections over actual
network connections. Combat remains outside that first playtest.

## Companion game integration and test guides

These files live in the sibling `construction-man` repository rather than this
extension repository:

- [Forklift movement integration and local rollback lab](../../../construction-man/testinghall/rollback_lab/README.md)
- [Phase 6A: two-process network input-correction tests](../../../construction-man/testinghall/rollback_lab/network/README.md)
- [Phase 6C: live input playtest and solo launcher](../../../construction-man/testinghall/rollback_lab/playtest/README.md)

Those relative links assume the repositories are checked out beside each other.
When browsing this repository alone, open `testinghall/rollback_lab/README.md` and
`testinghall/rollback_lab/network/README.md` in the game repository instead.

The game tests use actual forklift movement code. Combat, damage/destruction,
match lifecycle, production multiplayer integration and cross-platform validation
remain separate work. Passing the current tests does not imply those features
are implemented.

## How to read status and evidence

The implementation reports retain their original dates, test results and scope.
A statement that a feature was "later work" describes the milestone at the time
that report was written; use this index and the relevant newer guide for its
subsequent status. Historical Windows results do not establish Linux/SteamOS or
cross-platform determinism.

For future planning, update the performance plan as decisions are agreed before
implementing it. Additional phase documents can be added when their scope is
settled; empty placeholder reports are deliberately omitted.
