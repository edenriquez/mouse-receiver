# First Sprint Plan

## Sprint goal
Deliver a "feels real" single-edge handoff between two paired instances on macOS with no stuck modifiers and safe fallback to local control.

## Scope
- Screen-edge detection
- Forwarding state machine
- Input suppression on sender while forwarding
- Remote activation handshake
- Modifier state synchronization on activation/deactivation

## Non-goals
- Bonjour discovery
- Pairing UI
- launchd
- Multi-monitor mapping

## Milestones and acceptance criteria

### Milestone 1: Forwarding state machine and edge detection
- Edge decision logic is independent of CGEventTap and unit-testable.
- Hysteresis prevents rapid toggling.
- A single authoritative state drives suppression and transport.

### Milestone 2: Activation handshake and cursor teleport
- Sender requests activation with normalized cursor coordinates.
- Receiver acknowledges activation and warps cursor deterministically.
- If handshake fails or times out, sender remains local.

### Milestone 3: Input suppression safety
- When forwarding is active, forwarded events are suppressed locally.
- If connection drops, suppression stops immediately and local control returns.

### Milestone 4: Modifier synchronization
- Receiver maintains remote modifier state.
- On activation and deactivation, modifiers are reconciled so no modifiers remain stuck.

## Suggested task breakdown

### Week 1
- Implement forwarding state machine API and integrate with event capture.
- Implement edge detection with hysteresis and tests.
- Implement activation handshake messages and transitions.

### Week 2
- Implement suppression gating in event tap callback.
- Implement receiver modifier reconciliation logic.
- Add diagnostics logs around state transitions and reconnect fallback.

## Definition of done
- Two Macs can hand off control across one configured edge.
- No stuck modifiers after repeated handoffs.
- Network loss returns to local control within a bounded time.
- CPU stays stable during continuous mouse movement.
