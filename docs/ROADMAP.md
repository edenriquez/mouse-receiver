# 🗺️ Product Roadmap

## Phase 0 — Foundations (DONE / IN PROGRESS)

**Goal:** Prove correctness of primitives

* [x] CGEventTap input capture
* [x] CGEventPost injection
* [x] Cursor warping
* [x] Event normalization
* [x] TLS-based TCP transport
* [x] Intel + Apple Silicon compatibility

---

## Phase 1 — Seamless Interaction

**Goal:** Make it feel “real”

* [ ] Screen-edge detection
* [ ] Input suppression on sender while active
* [ ] Cursor teleport logic
* [ ] Modifier key state synchronization
* [ ] Key repeat correctness
* [ ] Scroll wheel fidelity

---

## Phase 2 — Discovery & Pairing

**Goal:** Zero-config LAN usage

* [ ] Bonjour service discovery
* [ ] Device identity & naming
* [ ] One-time pairing approval
* [ ] Trust persistence
* [ ] Rejection of unpaired devices

---

## Phase 3 — Stability & Lifecycle

**Goal:** Production reliability

* [ ] launchd agent
* [ ] Auto-start on login
* [ ] Sleep / wake recovery
* [ ] Network loss recovery
* [ ] Graceful shutdown
* [ ] Logging & diagnostics

---

## Phase 4 — User Control Surface

**Goal:** Minimal UX, no clutter

* [ ] Menu bar app
* [ ] Enable / disable sharing
* [ ] Active peer indicator
* [ ] Pairing UI
* [ ] Diagnostics panel (optional)

---

## Phase 5 — Advanced Capabilities (Optional)

**Goal:** Competitive parity with mature tools

* [ ] Multi-monitor mapping
* [ ] Directional screen layout
* [ ] Separate UDP channel for mouse movement
* [ ] Per-device profiles
* [ ] Latency optimization
* [ ] Event batching

---

## Phase 6 — Hardening & Distribution

**Goal:** Ship-quality product

* [ ] Code signing
* [ ] Hardened runtime
* [ ] Notarization
* [ ] Sandboxing strategy
* [ ] Installer packaging
* [ ] Update mechanism

---

## Long-Term (Nice-to-Have)

* Clipboard sharing
* Drag-and-drop handoff
* Keyboard layout sync
* HID-level abstraction (research)

---

## Success Criteria

* Feels indistinguishable from native behavior
* Trusted enough to run at login
* No fear of stuck input or crashes
* “Invisible” when working correctly
