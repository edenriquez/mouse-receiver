# ADR 0003: Edge Crossing and Handoff Behavior

## Status
Proposed

## Context
A convincing experience requires predictable edge crossing, no jitter at the boundary, and safe recovery if the receiver is not available. The system must avoid a state where both machines respond to input.

## Decision
- Use a two-phase handoff:
  - Phase A (candidate): sender detects edge and requests activation.
  - Phase B (active): receiver acknowledges activation and becomes active; sender suppresses local input.
- Apply hysteresis on the sender:
  - Enter candidate when cursor is within a threshold of the active edge.
  - Exit candidate only after cursor retreats beyond a larger threshold.
- Cursor teleport uses normalized coordinates mapped to the receiver active rectangle.
- On disconnect or handshake timeout, sender immediately returns to local mode and stops suppressing.

## Consequences
- Reduces boundary flapping and cursor jitter.
- Prevents ambiguous ownership of input.
- Requires a small control protocol for activation/deactivation.

## Alternatives considered
- One-way activation without acknowledgement: risks suppression without a receiver.
- Time-based suppression only: fails under network loss.

## Notes
- Multi-monitor support can extend the mapping model without changing the handoff phases.
