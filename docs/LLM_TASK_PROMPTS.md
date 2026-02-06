# LLM Task Prompts

Each item below is sized to fit a single PR.

## Phase 1 — Seamless Interaction

### 1. Screen-edge detection (sender)

**Goal**
Detect when the local cursor reaches the configured screen edge and trigger transition into "forwarding" mode.

**Acceptance criteria**
- Cursor position is sampled from the captured events and compared against the active screen geometry.
- A configurable edge (left/right/top/bottom) can be enabled.
- A small threshold (in points) is used to determine "at edge".
- Includes hysteresis so the state does not flap when cursor jitters near the edge.
- Unit-testable edge decision logic that does not depend on CGEventTap.

**Notes**
- Use points, not pixels, when reasoning about AppKit/CoreGraphics screen coordinates.

### 2. Input suppression while forwarding (sender)

**Goal**
When forwarding is active, local input is suppressed so the local machine does not also receive actions.

**Acceptance criteria**
- CGEventTap callback returns `nil` for events that are forwarded.
- Suppression is gated by a single authoritative state machine.
- Events needed to exit forwarding mode remain actionable (e.g. a hotkey).
- Does not block the event tap.

### 3. Cursor teleport and remote activation handshake

**Goal**
When edge crossing occurs, the receiver takes over cursor control smoothly and the sender stops locally.

**Acceptance criteria**
- A transition handshake exists so both sides agree which side is "active".
- Sender can send an activation message and the receiver responds with an acknowledgement.
- Receiver warps cursor to an initial position derived from normalized coordinates.
- Sender stops forwarding once the receiver is active.

### 4. Modifier key state synchronization

**Goal**
Prevent stuck modifiers across the boundary (Shift/Ctrl/Option/Command, Caps Lock).

**Acceptance criteria**
- Sender periodically includes modifier flags in keyboard events.
- Receiver maintains an authoritative remote modifier state.
- On activation and deactivation boundaries, receiver reconciles state by injecting missing up/down events.
- A recovery mechanism exists when packet loss occurs (idempotent updates).

### 5. Key repeat correctness

**Goal**
Ensure held-key behavior matches native expectations.

**Acceptance criteria**
- Distinguish between physical down/up and repeat-generated downs.
- Receiver injects appropriate events to match remote repeat behavior.
- No duplicated repeats when network jitter causes reordering.

### 6. Scroll wheel fidelity

**Goal**
Preserve smooth scrolling and direction on the receiver.

**Acceptance criteria**
- Sender captures precise scroll deltas and phase/momentum information when available.
- Receiver injects scroll events preserving pixel/line modes appropriately.
- No inverted scrolling if sender and receiver settings differ.

## Phase 2 — Discovery & Pairing

### 7. Bonjour service discovery

**Goal**
Advertise and discover peers on LAN.

**Acceptance criteria**
- A service type is defined and used consistently.
- Discovery produces a list of peers with stable IDs.
- Connection can be initiated from a discovered peer.

### 8. Device identity and naming

**Goal**
Provide a stable device identity across restarts and a friendly display name.

**Acceptance criteria**
- Stable ID is generated once and persisted.
- Friendly name is derived from system settings and can be overridden.

### 9. One-time pairing approval

**Goal**
Require explicit user approval before trusting a peer.

**Acceptance criteria**
- Pairing has a user-visible approval step.
- Peer is not able to inject input before approval.
- Pairing outcome is persisted.

### 10. Trust persistence and rejection of unpaired devices

**Goal**
Only accept input from previously trusted peers.

**Acceptance criteria**
- Peer trust is checked before processing any input messages.
- Unpaired peers are rejected with a clear reason.

## Phase 3 — Stability & Lifecycle

### 11. launchd agent

**Goal**
Run as a background agent managed by launchd.

**Acceptance criteria**
- LaunchAgent plist exists and can start the binary.
- Agent can run without UI.

### 12. Auto-start on login

**Goal**
Enable starting at login through launchd.

**Acceptance criteria**
- User can enable/disable login start.
- Behavior is persistent and reversible.

### 13. Sleep/wake recovery

**Goal**
Recover event tap and network state after sleep/wake.

**Acceptance criteria**
- Event tap is re-established when needed.
- Connections are re-established when peers are available.

### 14. Network loss recovery

**Goal**
Handle disconnects gracefully.

**Acceptance criteria**
- Detect disconnection quickly.
- Fall back to local control safely.
- Reconnect attempts follow a backoff.

### 15. Graceful shutdown

**Goal**
On shutdown or disable, return system to a clean state.

**Acceptance criteria**
- Event taps are invalidated.
- Modifier keys are reconciled.
- Receiver is deactivated and local input is restored.

### 16. Logging and diagnostics

**Goal**
Provide enough diagnostics to debug field issues.

**Acceptance criteria**
- Structured log categories exist.
- Redacts sensitive material.
- Includes connection state, active side, and input pipeline health.

## Phase 4 — User Control Surface

### 17. Menu bar controller

**Goal**
Provide minimal control without clutter.

**Acceptance criteria**
- Toggle enable/disable.
- Show active peer.
- Show pairing prompts.

## Phase 5 — Advanced Capabilities

### 18. Multi-monitor mapping

**Goal**
Support multiple displays on each device.

**Acceptance criteria**
- Mapping model supports multiple rectangles per device.
- Teleport logic uses mapping.

### 19. Separate mouse movement channel

**Goal**
Prepare transport to split mouse and keyboard.

**Acceptance criteria**
- Clear separation in transport abstraction.
- Can evolve to UDP without changing capture/injection layers.
