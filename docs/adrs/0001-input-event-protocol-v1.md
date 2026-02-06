# ADR 0001: Input Event Protocol v1

## Status
Proposed

## Context
The system needs a transport-friendly representation of input events that is low-latency, order-preserving, and safe against synthetic feedback loops. It must preserve enough data to reproduce keyboard and mouse behavior correctly, including modifier flags and scroll characteristics.

## Decision
- Use a length-prefixed message framing over `NWConnection`.
- Define an explicit message envelope with:
  - `protocolVersion`
  - `messageType`
  - `sequenceNumber`
  - `timestampMonotonicNs`
  - `sourceDeviceId`
  - `payload`
- Mouse position is represented as normalized coordinates in `[0, 1]` relative to an agreed active screen rectangle for the current session.
- Keyboard events represent virtual keycodes and explicit up/down transitions.
- Modifier state is included on every keyboard event and periodically on mouse movement when forwarding is active.

## Consequences
- The envelope enables detection of reordering and loss, and supports future extension.
- Normalized coordinates allow resolution-independent transport, but require an agreed mapping strategy.
- Including modifier state enables idempotent recovery and reduces risk of stuck modifiers.

## Alternatives considered
- Raw CGEvent field replication: too platform-coupled and brittle.
- JSON-only without framing: harder to parse reliably on a stream and less efficient.
- External serialization libraries: adds dependencies and long-term maintenance cost.

## Notes
- Separate channels for mouse movement and keyboard are compatible with the envelope approach by adding `channel` to the envelope or using independent connections.
