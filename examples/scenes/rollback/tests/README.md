# Multiplayer transport test

Run from the repository root:

```powershell
& 'C:/Program Files/Godot/Godot_v4.6-stable_win64.exe' --headless --path examples --script res://scenes/rollback/tests/input_transport_test.gd
```

The test checks retransmission, duplicate rejection, receipt versus consumption
acknowledgements, missing-frame recovery, jump edges, regulation under loss,
changing buffer targets, and bounded history recovery after a complete outage.
It advances transport deterministically; it is not a physics determinism test.

## Current regulation policy

Clients still produce one input for each fixed physics step. The server gently
adjusts consumption between 95% and 105% of that rate, occasionally holding an
input or combining two inputs for one step. Jump edges are preserved when inputs
are combined and are never repeated on a hold. This is downstream throttling,
not independent client simulation time scaling. It can introduce prediction
mismatches; snap correction remains enabled and rollback is not implemented.

The target now controls the running queue, as well as its initial fill. Packet
bursts are smoothed before calculating the consumption rate. Displayed counts
will fluctuate around the target. Total packet loss cannot be repaired until
communication resumes.

Clients resend up to 256 oldest unacknowledged frames per packet and retain up
to 1024 frames. Server receipt acknowledgements prune this transport history;
consumption acknowledgements remain separate. A very long outage can expire
history; those gaps are explicitly counted and skipped on recovery. This resend
history is not the future rollback state/input history.
